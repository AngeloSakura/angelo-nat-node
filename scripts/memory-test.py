#!/usr/bin/env python3
"""Real Linux cgroup memory smoke test, including both node and original Xray."""
import hashlib
import concurrent.futures
import http.client
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
        size = 8*1024*1024 if self.path == '/burst' else 32768
        data = b'x' * min(size, 65536)
        self.send_response(200)
        self.send_header('Content-Length', str(size))
        self.end_headers()
        try:
            for offset in range(0, size, len(data)):
                self.wfile.write(data[:min(len(data),size-offset)])
        except (BrokenPipeError, ConnectionResetError):
            pass  # caller reports the failed proxy request; avoid duplicate tracebacks
    def log_message(self, *args):
        pass

class TestServer(http.server.ThreadingHTTPServer):
    request_queue_size = 128
upstream = TestServer(('127.0.0.1', 0), Content)
threading.Thread(target=upstream.serve_forever, daemon=True).start()

def probe(memory):
    directory = pathlib.Path(tempfile.mkdtemp(prefix='angelo-mem-'))
    # Unique executable inodes + cache eviction prevent earlier CI integration
    # tests charging shared Xray code pages to a different cgroup.
    test_agent, test_xray = directory/'x-ui', directory/'xray'
    shutil.copy2(agent,test_agent)
    shutil.copy2(xray,test_xray)
    state = directory / 'state'
    config_path = directory / 'config.json'
    api_port, inbound_port, stats_port = port(), port(), port()
    subprocess.run([str(test_agent), '-init', '-config', str(config_path), '-state-dir', str(state), '-xray', str(test_xray), '-listen', f'127.0.0.1:{api_port}'], check=True, stdout=subprocess.DEVNULL)
    cfg = json.loads(config_path.read_text())
    cfg['apiAddress'] = f'127.0.0.1:{stats_port}'
    cfg['pollSeconds'] = 2
    cfg['directOutboundSettings'] = {'finalRules':[{'action':'allow','ip':['127.0.0.1'],'port':upstream.server_port}]}
    config_path.write_text(json.dumps(cfg))
    unit = f'angelo-test-{memory}-{os.getpid()}'
    for executable in (test_agent,test_xray):
        with executable.open('rb') as handle:
            os.fsync(handle.fileno())
            os.posix_fadvise(handle.fileno(),0,0,os.POSIX_FADV_DONTNEED)
    subprocess.run(['systemd-run', '--quiet', '--unit', unit, '--property', f'MemoryMax={memory}M', '--property', 'MemorySwapMax=0', '--property', 'KillMode=mixed', '--setenv', 'GOMEMLIMIT=12MiB', '--setenv', 'GOGC=50', '--setenv', 'GOMAXPROCS=1', str(test_agent), '-config', str(config_path)], check=True)
    cgroup=subprocess.check_output(['systemctl','show',unit,'--property','ControlGroup','--value'],text=True).strip()
    group=pathlib.Path('/sys/fs/cgroup'+cgroup)
    samples={'peakBytes':0,'anonPeakBytes':0,'socketPeakBytes':0,'summedRssPeakBytes':0,'summedPssPeakBytes':0,'oomKills':0}
    stop_sample=threading.Event()
    def sample():
        while not stop_sample.is_set():
            try:
                stats=dict(line.split() for line in (group/'memory.stat').read_text().splitlines())
                events=dict(line.split() for line in (group/'memory.events').read_text().splitlines())
                samples['peakBytes']=max(samples['peakBytes'],int((group/'memory.peak').read_text()))
                samples['anonPeakBytes']=max(samples['anonPeakBytes'],int(stats['anon']))
                samples['socketPeakBytes']=max(samples['socketPeakBytes'],int(stats['sock']))
                samples['oomKills']=max(samples['oomKills'],int(events['oom_kill']))
                rss=pss=0
                for pid in (group/'cgroup.procs').read_text().split():
                    try:
                        for line in pathlib.Path('/proc',pid,'smaps_rollup').read_text().splitlines():
                            parts=line.split()
                            if parts[0]=='Rss:': rss+=int(parts[1])*1024
                            elif parts[0]=='Pss:': pss+=int(parts[1])*1024
                    except OSError: pass
                samples['summedRssPeakBytes']=max(samples['summedRssPeakBytes'],rss)
                samples['summedPssPeakBytes']=max(samples['summedPssPeakBytes'],pss)
            except (OSError,KeyError): pass
            stop_sample.wait(.02)
    sampler=threading.Thread(target=sample,daemon=True)
    sampler.start()
    bursts=[]
    def request(path, data=None):
        body = None if data is None else json.dumps(data).encode()
        req = urllib.request.Request(f'https://127.0.0.1:{api_port}/panel/api/{path}', data=body, headers={'Authorization':'Bearer '+cfg['token'], 'Content-Type':'application/json'})
        with urllib.request.urlopen(req, context=ssl._create_unverified_context(), timeout=8) as response:
            obj = json.load(response)
        if not obj['success']:
            raise RuntimeError(obj['msg'])
        return obj['obj']
    def fetch(burst=False):
        with socket.create_connection(('127.0.0.1', inbound_port), timeout=3) as conn:
            conn.settimeout(30)
            path = b'/burst' if burst else b'/'
            conn.sendall(b'\x00'+bytes.fromhex('f0000000000040008000000000000001')+b'\x00\x01'+struct.pack('!H',upstream.server_port)+b'\x01\x7f\x00\x00\x01'+b'GET '+path+b' HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
            header = b''
            while len(header)<2:
                chunk=conn.recv(2-len(header))
                if not chunk: raise RuntimeError('missing VLESS response')
                header+=chunk
            if header!=b'\x00\x00': raise RuntimeError('unexpected VLESS response')
            response=http.client.HTTPResponse(conn)
            response.begin()
            size=0
            while True:
                chunk=response.read(65536)
                if not chunk: break
                size+=len(chunk)
            if size!=(8*1024*1024 if burst else 32768) or response.status!=200:
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
        client={'id':'f0000000-0000-4000-8000-000000000001','email':'alice','enable':True,'totalGB':2000000000}
        inbound={'enable':True,'port':inbound_port,'listen':'127.0.0.1','protocol':'vless','tag':'nat-test','settings':{'decryption':'none','clients':[client]},'streamSettings':{'network':'tcp','security':'none'}}
        request('inbounds/add',inbound)
        for i in range(30): fetch()
        cgroup=subprocess.check_output(['systemctl','show',unit,'--property','ControlGroup','--value'],text=True).strip()
        group=pathlib.Path('/sys/fs/cgroup'+cgroup)
        print(f'{memory} MiB cold-executable baseline passed; starting bursts',file=sys.stderr,flush=True)
        for concurrency in (8,32):
            started=time.monotonic()
            with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
                list(pool.map(lambda _:fetch(True),range(concurrency)))
            elapsed=time.monotonic()-started
            bursts.append({'connections':concurrency,'bytes':concurrency*8*1024*1024,'seconds':round(elapsed,3),'MiBPerSecond':round(concurrency*8/elapsed,2),'combinedPeakMiB':round(int((group/'memory.peak').read_text())/1048576,2)})
            print(json.dumps(bursts[-1]),file=sys.stderr,flush=True)
        time.sleep(2.5)
        before=request('inbounds/list')[0]['clientStats'][0]['down']
        if before<30*32768: raise RuntimeError(f'raw accounting missing: {before}')
        request('server/restartXrayService',{})
        fetch()
        time.sleep(2.5)
        after=request('inbounds/list')[0]['clientStats'][0]['down']
        if after<=before: raise RuntimeError('restart lost counter continuity')
        request('inbounds/pushClientTraffics',{'masterGuid':'test-master','traffics':[{'email':'alice','up':0,'down':2000000000}]})
        try: fetch()
        except (OSError,RuntimeError): pass
        else: raise RuntimeError('billed quota did not stop forwarding')
        raw=request('inbounds/list')[0]['clientStats'][0]['down']
        if raw>=2000000000: raise RuntimeError('master billed usage contaminated raw counters')
        request('clients/resetTraffic/alice',{})
        fetch()
        cgroup=subprocess.check_output(['systemctl','show',unit,'--property','ControlGroup','--value'],text=True).strip()
        group=pathlib.Path('/sys/fs/cgroup'+cgroup)
        current=int((group/'memory.current').read_text())
        peak=int((group/'memory.peak').read_text())
        events=dict(line.split() for line in (group/'memory.events').read_text().splitlines())
        if int(events.get('oom_kill','0')): raise RuntimeError('OOM killed a process')
        result={'passed':True,'limitMiB':memory,'combinedCurrentMiB':round(current/1048576,2),'combinedPeakMiB':round(peak/1048576,2),'oomKills':int(events['oom_kill']),'requests':72,'bursts':bursts,'rawBytesBeforeReset':raw,'swap':False,'sampledMemory':samples}
        return result
    except Exception as error:
        return {'passed':False,'limitMiB':memory,'error':str(error),'bursts':bursts,'sampledMemory':samples}
    finally:
        stop_sample.set()
        sampler.join()
        subprocess.run(['systemctl','stop',unit],check=False,stdout=subprocess.DEVNULL)
        subprocess.run(['journalctl','-u',unit,'--no-pager','-n','12'],check=False,stdout=sys.stderr)
        shutil.rmtree(directory)

results=[probe(64),probe(128)]
upstream.shutdown()
print(json.dumps({'results':results,'scope':'64/128 MiB cgroup of agent+Xray, one VLESS TCP client, plain transport; host OS excluded; not a full 64 MiB VPS guarantee'},indent=2))
sys.exit(0 if all(result['passed'] for result in results) else 1)
