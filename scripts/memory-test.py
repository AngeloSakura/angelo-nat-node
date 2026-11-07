#!/usr/bin/env python3
"""Real Linux cgroup memory smoke test, including both node and original Xray."""
import hashlib
import http.server
import json
import os
import pathlib
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

agent, xray = map(lambda p: str(pathlib.Path(p).resolve()), sys.argv[1:])

def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

class Content(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data = b'x' * 32768
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args):
        pass

upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Content)
threading.Thread(target=upstream.serve_forever, daemon=True).start()

def probe(memory):
    directory = pathlib.Path(tempfile.mkdtemp(prefix='angelo-mem-'))
    state = directory / 'state'
    config_path = directory / 'config.json'
    api_port, inbound_port, stats_port = port(), port(), port()
    subprocess.run([agent, '-init', '-config', str(config_path), '-state-dir', str(state), '-xray', xray, '-listen', f'127.0.0.1:{api_port}'], check=True, stdout=subprocess.DEVNULL)
    cfg = json.loads(config_path.read_text())
    cfg['apiAddress'] = f'127.0.0.1:{stats_port}'
    cfg['pollSeconds'] = 2
    config_path.write_text(json.dumps(cfg))
    unit = f'angelo-test-{memory}-{os.getpid()}'
    subprocess.run(['systemd-run', '--quiet', '--unit', unit, '--property', f'MemoryMax={memory}M', '--property', 'MemorySwapMax=0', '--property', 'KillMode=mixed', '--setenv', 'GOMEMLIMIT=12MiB', '--setenv', 'GOGC=50', '--setenv', 'GOMAXPROCS=1', agent, '-config', str(config_path)], check=True)
    def request(path, data=None):
        body = None if data is None else json.dumps(data).encode()
        req = urllib.request.Request(f'https://127.0.0.1:{api_port}/panel/api/{path}', data=body, headers={'Authorization':'Bearer '+cfg['token'], 'Content-Type':'application/json'})
        with urllib.request.urlopen(req, context=ssl._create_unverified_context(), timeout=8) as response:
            obj = json.load(response)
        if not obj['success']:
            raise RuntimeError(obj['msg'])
        return obj['obj']
    def fetch():
        with socket.create_connection(('127.0.0.1', inbound_port), timeout=3) as conn:
            conn.settimeout(3)
            conn.sendall(b'\x00'+bytes.fromhex('f0000000000040008000000000000001')+b'\x00\x01'+struct.pack('!H',upstream.server_port)+b'\x01\x7f\x00\x00\x01'+b'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
            data = b''
            while True:
                chunk = conn.recv(65536)
                if not chunk: break
                data += chunk
            if len(data)<32768 or b'200 OK' not in data:
                raise RuntimeError('forwarding failed')
    try:
        for attempt in range(60):
            try:
                status=request('server/status')
                if status['xray']['state']=='running': break
            except Exception:
                pass
            time.sleep(.2)
        else: raise RuntimeError('startup failed under memory limit')
        client={'id':'f0000000-0000-4000-8000-000000000001','email':'alice','enable':True,'totalGB':100000000}
        inbound={'enable':True,'port':inbound_port,'listen':'127.0.0.1','protocol':'vless','tag':'nat-test','settings':{'decryption':'none','clients':[client]},'streamSettings':{'network':'tcp','security':'none'}}
        request('inbounds/add',inbound)
        for i in range(30): fetch()
        time.sleep(2.5)
        before=request('inbounds/list')[0]['clientStats'][0]['down']
        if before<30*32768: raise RuntimeError(f'raw accounting missing: {before}')
        request('server/restartXrayService',{})
        fetch()
        time.sleep(2.5)
        after=request('inbounds/list')[0]['clientStats'][0]['down']
        if after<=before: raise RuntimeError('restart lost counter continuity')
        request('inbounds/pushClientTraffics',{'masterGuid':'test-master','traffics':[{'email':'alice','up':0,'down':100000000}]})
        try: fetch()
        except (OSError,RuntimeError): pass
        else: raise RuntimeError('billed quota did not stop forwarding')
        raw=request('inbounds/list')[0]['clientStats'][0]['down']
        if raw>=100000000: raise RuntimeError('master billed usage contaminated raw counters')
        request('clients/resetTraffic/alice',{})
        fetch()
        cgroup=subprocess.check_output(['systemctl','show',unit,'--property','ControlGroup','--value'],text=True).strip()
        group=pathlib.Path('/sys/fs/cgroup'+cgroup)
        current=int((group/'memory.current').read_text())
        peak=int((group/'memory.peak').read_text())
        events=dict(line.split() for line in (group/'memory.events').read_text().splitlines())
        if int(events.get('oom_kill','0')): raise RuntimeError('OOM killed a process')
        result={'limitMiB':memory,'combinedCurrentMiB':round(current/1048576,2),'combinedPeakMiB':round(peak/1048576,2),'oomKills':int(events['oom_kill']),'requests':32,'rawBytesBeforeReset':raw,'swap':False}
        return result
    finally:
        subprocess.run(['systemctl','stop',unit],check=False,stdout=subprocess.DEVNULL)
        subprocess.run(['journalctl','-u',unit,'--no-pager','-n','12'],check=False,stdout=sys.stderr)
        shutil.rmtree(directory)

results=[probe(64),probe(128)]
upstream.shutdown()
print(json.dumps({'results':results,'scope':'64/128 MiB cgroup of agent+Xray, one VLESS TCP client, plain transport; host OS excluded; not a full 64 MiB VPS guarantee'},indent=2))
