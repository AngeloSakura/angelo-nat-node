#!/usr/bin/env bash
# Real unchanged upstream master -> lightweight node named x-ui -> unchanged bundled Xray.
# Run only on a disposable Linux amd64 root/systemd CI runner:
# sudo bash scripts/test-master-node-live.sh /absolute/path/to/angelo-node
# Uses loopback HTTP strictly inside this isolated fixture, never for deployment.
set +x
set -Eeuo pipefail
umask 077
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
[[ $# == 1 && -f $1 && -x $1 ]] || { echo 'Provide the built Linux amd64 angelo-node executable.' >&2; exit 1; }
agent=$(realpath -e -- "$1")
[[ $(id -u) == 0 && $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'Disposable root Linux amd64 required.' >&2; exit 1; }
[[ -d /run/systemd/system && $(cat /proc/1/comm) == systemd ]] || { echo 'Real systemd PID 1 required.' >&2; exit 1; }
for command in python3 curl systemctl timeout sha256sum mktemp cp; do command -v "$command" >/dev/null; done
python3 -c 'import sys,sqlite3; assert sys.version_info >= (3,9)'
[[ -f $script_dir/test-master-live.sh ]] || { echo 'Shared pinned master fixture helper missing.' >&2; exit 1; }
root=$(mktemp -d /var/tmp/angelo-interoperability.XXXXXXXX)
readonly root
master_service=$(basename "$root")-master.service
node_service=$(basename "$root")-node.service
created_master=0 created_node=0
cleanup() {
    local code=$? stopped=1
    trap - EXIT INT TERM
    set +e
    if ((created_master)); then
        systemctl stop "$master_service" >/dev/null 2>&1
        [[ $(systemctl show --property=MainPID --value "$master_service") == 0 ]] || stopped=0
    fi
    if ((created_node)); then
        systemctl stop "$node_service" >/dev/null 2>&1
        [[ $(systemctl show --property=MainPID --value "$node_service") == 0 ]] || stopped=0
    fi
    if ((!stopped)); then echo "Temporary process still running; private fixture retained: $root" >&2; exit 1; fi
    if ((created_master)); then rm -f -- "/run/systemd/system/$master_service"; systemctl reset-failed "$master_service" >/dev/null 2>&1; fi
    if ((created_node)); then rm -f -- "/run/systemd/system/$node_service"; systemctl reset-failed "$node_service" >/dev/null 2>&1; fi
    systemctl daemon-reload
    if [[ $root =~ ^/var/tmp/angelo-interoperability\.[A-Za-z0-9]{8}$ && ! -L $root ]]; then rm -rf -- "$root"; else code=1; fi
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$root/install" "$root/db" "$root/log" "$root/backups" "$root/node"
cp -- "$agent" "$root/node/x-ui"
chmod 755 "$root/node/x-ui"
echo 'Downloading SHA-pinned upstream v1.0.0 master and its original Xray...'
curl -q -fLsS --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 180 --max-filesize 134217728 \
    --output "$root/master.tar.gz" -- https://github.com/AngeloSakura/Angelo-xui-plugin-2/releases/download/v1.0.0/x-ui-linux-amd64.tar.gz
printf '%s  %s\n' 96a6518eee572bc282ce5c56ece59b4b4f3332be9ee24ffd29e6993c3782f1a5 "$root/master.tar.gz" | sha256sum --check --status
# Reuse only the audited extraction/CLI-initialization helper, never source the
# first test's shell or invoke its updater. This keeps archive/schema setup shared.
python3 - "$script_dir/test-master-live.sh" "$root/fixture.py" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
start = 'cat >"$root/check.py" <<\'PY\'\n'
if text.count(start) != 1: raise RuntimeError('Shared fixture marker changed')
helper = text.split(start,1)[1].split('\nPY\n',1)[0]
compile(helper, 'fixture.py', 'exec')
pathlib.Path(sys.argv[2]).write_text(helper)
PY
python3 "$root/fixture.py" extract "$root"
python3 "$root/fixture.py" init "$root" >/dev/null
cat >"$root/interoperability.py" <<'PY'
import hashlib, http.client, http.server, json, pathlib, secrets, socket, sqlite3, struct, sys, threading, time, urllib.error, urllib.request, uuid
mode, root = sys.argv[1], pathlib.Path(sys.argv[2]).resolve()
s = json.loads((root / 'state.json').read_text())
def require(value, message):
    if not value: raise RuntimeError(message)
def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda:f.read(1048576),b''): h.update(block)
    return h.hexdigest()
if mode == 'prepare':
    sockets=[]
    for _ in range(3):
        sock=socket.socket(); sock.bind(('127.0.0.1',0)); sockets.append(sock)
    s.update(zip(('node_port','node_stats_port','source_port'),[x.getsockname()[1] for x in sockets]))
    s['node_api_token']=secrets.token_hex(24)
    s['node_base']='/node-'+secrets.token_hex(8)+'/'
    s['xray_sha']=digest(root/'install/bin/xray-linux-amd64')
    s['master_sha']=digest(root/'install/x-ui')
    config={'listen':'127.0.0.1:'+str(s['node_port']),'token':s['node_api_token'],'basePath':s['node_base'],
            'stateDir':str(root/'node/state'),'xrayPath':str(root/'install/bin/xray-linux-amd64'),
            'apiAddress':'127.0.0.1:'+str(s['node_stats_port']),'pollSeconds':2,'maxClients':4,'maxInbounds':2,
            'directOutboundSettings':{'finalRules':[{'action':'allow','ip':['127.0.0.1'],'port':s['source_port']},{'action':'block'}]}}
    (root/'node/config.json').write_text(json.dumps(config))
    (root/'state.json').write_text(json.dumps(s))
    for sock in sockets: sock.close()
    sys.exit(0)
require(mode == 'run','Unknown mode')
deadline=time.monotonic()+300
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs): return None
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
def api(kind,route,payload=None,invalid=False):
    port,base,token=(s['port'],s['base'],s['token']) if kind=='master' else (s['node_port'],s['node_base'],s['node_api_token'])
    headers={'Authorization':'Bearer '+('invalid-token-for-negative-control' if invalid else token),'Content-Type':'application/json','X-Requested-With':'XMLHttpRequest'}
    req=urllib.request.Request('http://127.0.0.1:'+str(port)+base+'panel/api/'+route,
                              data=None if payload is None else json.dumps(payload).encode(),headers=headers)
    with opener.open(req,timeout=10) as response: result=json.load(response)
    require(result.get('success') is True, kind+' API rejected '+route)
    return result.get('obj')
def wait(label,predicate,seconds=60):
    limit=min(deadline,time.monotonic()+seconds)
    while time.monotonic()<limit:
        try:
            result=predicate()
            if result: return result
        except (urllib.error.URLError,TimeoutError,ConnectionError,OSError): pass
        time.sleep(1)
    raise RuntimeError('Timed out: '+label)
def dbrow(sql,params=()):
    with sqlite3.connect((root/'db/x-ui.db').as_uri()+'?mode=ro',uri=True,timeout=5) as db:
        db.row_factory=sqlite3.Row
        row=db.execute(sql,params).fetchone()
        return None if row is None else dict(row)
def node_rows(): return api('node','inbounds/list')
def node_client():
    for inbound in node_rows():
        for row in inbound.get('clientStats',[]):
            if row.get('email')==s['email']: return row
    return None
def global_row():
    state=json.loads((root/'node/state/state.json').read_text())
    return state.get('global',{}).get(s['guid'],{}).get(s['email'])
def source_bytes():
    try:
        with socket.create_connection(('127.0.0.1',s['inbound_port']),timeout=3) as conn:
            conn.settimeout(3)
            header=b'\x00'+uuid.UUID(s['uuid']).bytes+b'\x00\x01'+struct.pack('!H',s['source_port'])+b'\x01\x7f\x00\x00\x01'
            conn.sendall(header+b'GET /payload HTTP/1.1\r\nHost: fixture\r\nConnection: close\r\n\r\n')
            def exact(n):
                out=b''
                while len(out)<n:
                    piece=conn.recv(n-len(out))
                    if not piece: raise ConnectionError('Proxy closed before response')
                    out+=piece
                return out
            response=exact(2)
            if response[0]!=0: return False
            if response[1]: exact(response[1])
            parsed=http.client.HTTPResponse(conn); parsed.begin()
            body=parsed.read(32769)
            return parsed.status==200 and body==b'x'*32768
    except (OSError,EOFError,http.client.HTTPException): return False
class Source(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        payload=b'x'*32768
        self.send_response(200); self.send_header('Content-Length',str(len(payload))); self.end_headers()
        self.wfile.write(payload)
    def log_message(self,*args): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',s['source_port']),Source)
threading.Thread(target=server.serve_forever,daemon=True).start()
try:
    wait('master API',lambda:api('master','server/status'))
    wait('node Xray health',lambda:api('node','server/health'))
    for kind in ('master','node'):
        try: api(kind,'server/status',invalid=True)
        except urllib.error.HTTPError as error: require(error.code in (401,403,404),'Unexpected negative-auth status')
        else: raise RuntimeError(kind+' accepted invalid Bearer token')
    node=api('master','nodes/add',{'name':'isolated-angelo-node','scheme':'http','address':'127.0.0.1',
         'port':s['node_port'],'basePath':s['node_base'],'apiToken':s['node_api_token'],'enable':True,
         'allowPrivateAddress':True,'tlsVerifyMode':'verify','inboundSyncMode':'all','inboundTags':[],
         'trafficMultiplier':2.5})
    node_id=node['id']
    require(node.get('hasApiToken') is True and node.get('trafficMultiplier')==2.5,'Master did not retain node credentials/multiplier')
    wait('master heartbeat',lambda:api('master','nodes/get/'+str(node_id)).get('status')=='online')
    inbound=api('master','inbounds/add',{'nodeId':node_id,'enable':True,'remark':'real-master-node-smoke',
        'listen':'127.0.0.1','port':s['inbound_port'],'protocol':'vless','tag':'live-vless','up':0,'down':0,
        'total':0,'expiryTime':0,'trafficReset':'never','trafficResetDay':1,
        'settings':{'clients':[],'decryption':'none'},'streamSettings':{'network':'tcp','security':'none'},
        'sniffing':{'enabled':False},'shareAddrStrategy':'node'})
    inbound_id=inbound['id']
    client={'id':s['uuid'],'email':s['email'],'enable':True,'flow':'','security':'auto','limitIp':0,
        'totalGB':1073741824,'expiryTime':0,'subId':secrets.token_hex(8),'reset':0,'trafficReset':'never','trafficResetDay':1}
    api('master','clients/add',{'client':client,'inboundIds':[inbound_id]})
    wait('master-created client on node',lambda:node_client())
    require(api('node','server/health')['xray']['state']=='running','Node Xray failed after master-created inbound')
    # First upstream poll only establishes a raw baseline. Never send traffic first.
    wait('master raw baseline',lambda:dbrow('SELECT up,down FROM node_client_traffics WHERE node_id=? AND email=?',(node_id,s['email'])))
    baseline=node_client()
    billed_before=api('master','clients/traffic/'+s['email'])
    raw_before=(baseline['up'],baseline['down'])
    require(raw_before==(0,0),'Unexpected prior node traffic')
    require(billed_before['up']==0 and billed_before['down']==0,'Unexpected prior master traffic')
    require(source_bytes(),'Master-created client could not proxy the exact local payload')
    raw=wait('raw Xray counters',lambda:(lambda x:x if x and x['down']>=32768 else None)(node_client()),30)
    # Requests and response headers are real traffic; compare against Xray counters,
    # not payload alone. Rounding is once per poll; allow at most 8 bytes/direction.
    require(32768<=raw['down']<40000 and 0<raw['up']<4096,'Unexpected raw transfer size')
    def billed_ready():
        live=node_client(); billed=api('master','clients/traffic/'+s['email'])
        if all(abs(billed[k]-2.5*live[k])<=8 for k in ('up','down')) and billed['down']>=81920: return live,billed
    raw,billed=wait('2.5x billed counters from real master sync',billed_ready,60)
    master_baseline=dbrow('SELECT up,down FROM node_client_traffics WHERE node_id=? AND email=?',(node_id,s['email']))
    require(master_baseline and all(master_baseline[k]==raw[k] for k in ('up','down')),'Master baseline was multiplied instead of remaining raw')
    def global_ready():
        row=global_row()
        return row if row and all(abs(row[k]-billed[k])<=8 for k in ('up','down')) else None
    wait('real master global push',global_ready,65)
    stable_raw=(raw['up'],raw['down'])
    stable_billed=(billed['up'],billed['down'])
    # Survive another real 30-second push cycle: pushed billing must not feed back
    # into the node raw counters or be multiplied again on the next master poll.
    until=time.monotonic()+35
    while time.monotonic()<until:
        live=node_client(); current=api('master','clients/traffic/'+s['email'])
        require((live['up'],live['down'])==stable_raw,'Pushed globals contaminated node raw counters')
        require((current['up'],current['down'])==stable_billed,'Master counted pushed usage again')
        time.sleep(2)
    print('PASS actual master nodes/add, inbound/client creation, VLESS bytes, 2.5x billing and no feedback',flush=True)
    # A limit between raw and billed usage isolates multiplier-based enforcement.
    raw_total=sum(stable_raw); billed_total=sum(stable_billed)
    quota=(raw_total+billed_total)//2
    require(raw_total<quota<billed_total,'Invalid billed-only quota')
    client['totalGB']=quota
    api('master','clients/update/'+s['email'],client)
    def depleted():
        live=node_client()
        return live if live and live.get('total')==quota and live.get('enable') is False else None
    wait('master-driven billed quota enforcement',depleted,65)
    require(not source_bytes(),'Billed-quota exhausted client still forwarded payload')
    # Keep an independently healthy Xray as the negative control for denial.
    require(api('node','server/health')['xray']['state']=='running','Denial was caused by an unhealthy Xray')
    still=node_client()
    require(still['up']+still['down']<quota,'Local raw quota, not multiplied billing, caused denial')
    require(global_row()['up']+global_row()['down']>=quota,'No real master global usage was delivered')
    client['totalGB']=1073741824
    client['enable']=True
    api('master','clients/update/'+s['email'],client)
    wait('master raised quota and re-enabled client',lambda:(lambda x:x and x.get('total')==1073741824 and x.get('enable') is True)(node_client()),65)
    require(source_bytes(),'Raising quota through master did not restore proxy traffic')
    api('master','clients/del/'+s['email'],{})
    wait('master client deletion propagated',lambda:node_client() is None,60)
    require(not source_bytes(),'Deleted client still forwarded traffic')
    require(api('node','server/health')['xray']['state']=='running','Deletion denial was caused by unhealthy Xray')
    require(digest(root/'install/bin/xray-linux-amd64')==s['xray_sha'],'Original Xray file changed')
    require(digest(root/'install/x-ui')==s['master_sha'],'Original master file changed')
    print('PASS actual master quota update, billed-only denial, restored traffic and deletion; both upstream binaries unchanged',flush=True)
    print(json.dumps({'rawUp':stable_raw[0],'rawDown':stable_raw[1],'billedUp':stable_billed[0],
                      'billedDown':stable_billed[1],'multiplier':2.5,'billedOnlyQuota':quota,'roundingToleranceBytes':8}),flush=True)
finally:
    server.shutdown(); server.server_close()
PY
python3 "$root/interoperability.py" prepare "$root"
for role in master node; do
    if [[ $role == master ]]; then
        service=$master_service; executable=$root/install/x-ui; arguments=; directory=$root/install
    else
        service=$node_service; executable=$root/node/x-ui; arguments=" -config $root/node/config.json"; directory=$root/node
    fi
    [[ ! -e /run/systemd/system/$service ]] || { echo 'Temporary unit name collision.' >&2; exit 1; }
    cat >"/run/systemd/system/$service" <<UNIT
[Unit]
Description=Isolated Angelo real master-node interoperability smoke
[Service]
Type=simple
WorkingDirectory=$directory
ExecStart=$executable$arguments
Environment=XUI_DB_TYPE=sqlite
Environment=XUI_DB_FOLDER=$root/db
Environment=XUI_BIN_FOLDER=$root/install/bin
Environment=XUI_LOG_FOLDER=$root/log
Environment=XUI_NODE_TOKEN_KEY_FILE=$root/db/node_token_key.json
Environment=NODE_TOKEN_ENCRYPTION=off
Environment=HOME=$root
Restart=no
TimeoutStopSec=30
KillMode=control-group
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$root
InaccessiblePaths=-/etc/x-ui -/usr/local/x-ui -/var/log/x-ui
IPAddressDeny=any
IPAddressAllow=localhost
StandardOutput=append:$root/$role.log
StandardError=append:$root/$role.log
UNIT
    if [[ $role == master ]]; then created_master=1; else created_node=1; fi
done
systemctl daemon-reload
systemctl start "$node_service"
systemctl start "$master_service"
node_pid=$(systemctl show --property=MainPID --value "$node_service")
[[ $node_pid =~ ^[1-9][0-9]*$ ]] || { echo 'Node service has no live MainPID' >&2; exit 1; }
[[ $(cat "/proc/$node_pid/comm") == x-ui ]] || { echo 'Node executable process name is not x-ui' >&2; exit 1; }
[[ $(readlink -f "/proc/$node_pid/exe") == "$root/node/x-ui" ]] || { echo 'Node process is not running the x-ui executable' >&2; exit 1; }
echo 'Running real master API control, multiplier synchronization and billed-quota enforcement...'
timeout --signal=TERM --kill-after=10s 330s python3 "$root/interoperability.py" run "$root"
