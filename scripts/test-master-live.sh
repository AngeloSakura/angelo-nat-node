#!/usr/bin/env bash
# Disposable root Linux/systemd CI only. No production paths or services touched.
# Real pinned master, its bundled unchanged Xray, and actual update-master.sh.
# Same-version preservation smoke, not cross-version migration or memory testing.
set +x
set -Eeuo pipefail
umask 077
readonly archive_sha=96a6518eee572bc282ce5c56ece59b4b4f3332be9ee24ffd29e6993c3782f1a5
readonly archive_url=https://github.com/AngeloSakura/Angelo-xui-plugin-2/releases/download/v1.0.0/x-ui-linux-amd64.tar.gz
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
[[ $(id -u) == 0 && $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'Root Linux amd64 required.' >&2; exit 1; }
[[ -d /run/systemd/system && $(cat /proc/1/comm) == systemd ]] || { echo 'Real systemd PID 1 required.' >&2; exit 1; }
for command in python3 curl systemctl timeout sha256sum mktemp realpath; do
    command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
python3 -c 'import sys,sqlite3; assert sys.version_info >= (3,9)'
[[ -f $script_dir/update-master.sh ]] || { echo 'Actual updater missing.' >&2; exit 1; }
root=$(mktemp -d /var/tmp/angelo-master-live.XXXXXXXX)
readonly root
service=$(basename "$root").service
unit=/run/systemd/system/$service
created_unit=0
cleanup() {
    local code=$?
    trap - EXIT INT TERM
    set +e
    if ((created_unit)); then
        systemctl stop "$service" >/dev/null 2>&1
        if systemctl is-active --quiet "$service" || [[ $(systemctl show --property=MainPID --value "$service" 2>/dev/null) != 0 ]]; then
            echo "Temporary service failed to stop; private fixture retained: $root" >&2
            exit 1
        fi
        systemctl reset-failed "$service" >/dev/null 2>&1
        rm -f -- "$unit"
        systemctl daemon-reload
    fi
    if [[ $root =~ ^/var/tmp/angelo-master-live\.[A-Za-z0-9]{8}$ && ! -L $root ]]; then
        rm -rf -- "$root"
    else
        echo 'Unexpected cleanup path refused.' >&2
        code=1
    fi
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$root/install" "$root/db" "$root/log" "$root/backups"
echo 'Downloading and verifying the pinned official master...'
curl -q -fLsS --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 240 --retry 1 --max-filesize 134217728 --output "$root/master.tar.gz" -- "$archive_url"
printf '%s  %s\n' "$archive_sha" "$root/master.tar.gz" | sha256sum --check --status
cat >"$root/check.py" <<'PY'
import hashlib, http.cookiejar, json, os, pathlib, secrets, socket, sqlite3, subprocess, sys, tarfile, time, urllib.request, uuid
mode, root = sys.argv[1], pathlib.Path(sys.argv[2]).resolve()
state_path = root / 'state.json'
def require(value, message):
    if not value: raise RuntimeError(message)
def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1048576), b''): h.update(block)
    return h.hexdigest()
def connect(readonly=False):
    db = sqlite3.connect((root / 'db/x-ui.db').as_uri() + ('?mode=ro' if readonly else '?mode=rw'), uri=True, timeout=10)
    db.row_factory = sqlite3.Row
    return db
def columns(db, table):
    return {r['name'] for r in db.execute('PRAGMA table_info(' + table + ')')}
def insert(db, table, values):
    require(set(values) <= columns(db, table), 'Pinned schema mismatch: ' + table)
    keys = list(values)
    db.execute('INSERT INTO ' + table + ' (' + ','.join('"' + k + '"' for k in keys) + ') VALUES (' + ','.join('?' for _ in keys) + ')', [values[k] for k in keys])
def read_state():
    return json.loads(state_path.read_text())
if mode == 'extract':
    wanted = {'x-ui/x-ui': 'x-ui', 'x-ui/bin/xray-linux-amd64': 'bin/xray-linux-amd64'}
    seen = set()
    with tarfile.open(root / 'master.tar.gz', 'r|gz') as archive:
        for member in archive:
            name = member.name.removeprefix('./')
            if name not in wanted: continue
            require(name not in seen and member.isfile() and 64 <= member.size <= 128*1024*1024, 'Unexpected archive member')
            seen.add(name)
            target = root / 'install' / wanted[name]
            target.parent.mkdir(exist_ok=True)
            with archive.extractfile(member) as src, open(target, 'xb') as dst:
                while True:
                    block = src.read(1048576)
                    if not block: break
                    dst.write(block)
            with target.open('rb') as src: require(src.read(6) == b'\x7fELF\x02\x01', 'Expected ELF64')
            target.chmod(0o755)
    require(seen == set(wanted), 'Missing runtime executable')
    sockets = []
    for _ in range(3):
        sock = socket.socket(); sock.bind(('127.0.0.1', 0)); sockets.append(sock)
    ports = [s.getsockname()[1] for s in sockets]
    state = {'port': ports[0], 'api_port': ports[1], 'inbound_port': ports[2],
             'username': 'smoke-' + secrets.token_hex(6), 'password': secrets.token_hex(24),
             'token': secrets.token_hex(24), 'base': '/smoke-' + secrets.token_hex(8) + '/',
             'email': 'smoke-' + secrets.token_hex(6), 'uuid': str(uuid.uuid4()),
             'node_token': secrets.token_hex(24), 'guid': str(uuid.uuid4())}
    state_path.write_text(json.dumps(state))
    for s in sockets: s.close()
    # Opaque preservation fixture only: encrypted-token mode is not under test.
    (root / 'db/node_token_key.json').write_text(json.dumps({'smokeMarker': secrets.token_hex(32)}))
    (root / 'db/node_token_key.json').chmod(0o600)
elif mode == 'init':
    s = read_state()
    env = {'PATH': os.environ['PATH'], 'HOME': str(root), 'XUI_DB_TYPE': 'sqlite',
           'XUI_DB_FOLDER': str(root / 'db'), 'XUI_BIN_FOLDER': str(root / 'install/bin'),
           'XUI_LOG_FOLDER': str(root / 'log'), 'XUI_NODE_TOKEN_KEY_FILE': str(root / 'db/node_token_key.json'),
           'NODE_TOKEN_ENCRYPTION': 'off'}
    with (root / 'initialize.log').open('wb') as log:
        subprocess.run([str(root / 'install/x-ui'), 'setting', '-port', str(s['port']),
            '-listenIP', '127.0.0.1', '-webBasePath', s['base'], '-username', s['username'], '-password', s['password']],
            cwd=root / 'install', env=env, stdout=log, stderr=log, check=True, timeout=45)
    with connect() as db:
        require(db.execute('PRAGMA quick_check').fetchone()[0] == 'ok', 'SQLite initialization failed')
        template = {'log': {'access': 'none', 'error': 'none', 'loglevel': 'warning'},
            'api': {'tag': 'api', 'services': ['HandlerService','LoggerService','StatsService','RoutingService']},
            'inbounds': [{'listen':'127.0.0.1','port':s['api_port'],'protocol':'tunnel','settings':{'rewriteAddress':'127.0.0.1'},'tag':'api'}],
            'outbounds': [{'protocol':'blackhole','tag':'blocked'}],
            'routing': {'rules':[{'type':'field','inboundTag':['api'],'outboundTag':'api'}]},
            'policy': {'levels':{'0':{'statsUserUplink':True,'statsUserDownlink':True}},'system':{'statsInboundUplink':True,'statsInboundDownlink':True}}, 'stats':{}}
        values = {'subEnable':'false','subJsonEnable':'false','subClashEnable':'false','tgBotEnable':'false',
                  'webDomain':'','twoFactorEnable':'false','webCertFile':'','webKeyFile':'',
                  'panelGuid':s['guid'],'xrayTemplateConfig':json.dumps(template)}
        for key, value in values.items():
            db.execute('DELETE FROM settings WHERE key=?', (key,))
            insert(db, 'settings', {'key':key,'value':value})
        insert(db, 'api_tokens', {'name':'master-live-smoke','token':hashlib.sha256(s['token'].encode()).hexdigest(),
                                 'enabled':1,'created_at':int(time.time()),'scope':'admin','expires_at':0})
        # Disabled remote node: its saved token/multiplier are exercised without polling another panel.
        insert(db, 'nodes', {'name':'master-live-disabled-node','scheme':'http','address':'127.0.0.1',
                            'port':s['inbound_port'],'base_path':'/','api_token':s['node_token'],
                            'enable':0,'traffic_multiplier':2.5,'tls_verify_mode':'verify',
                            'inbound_sync_mode':'all','inbound_tags':'[]'})
    print(s['port'])
elif mode in ('api-seed', 'api-check'):
    s = read_state()
    base = 'http://127.0.0.1:' + str(s['port']) + s['base']
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs): return None
    cookies = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(cookies), NoRedirect())
    def request(path, data=None, bearer=True, csrf=None):
        headers = {'Accept':'application/json','X-Requested-With':'XMLHttpRequest'}
        if bearer: headers['Authorization'] = 'Bearer ' + s['token']
        if csrf: headers['X-CSRF-Token'] = csrf
        if data is not None: headers['Content-Type'] = 'application/json'
        req = urllib.request.Request(base + path, data=None if data is None else json.dumps(data).encode(), headers=headers)
        with opener.open(req, timeout=10) as response:
            require(response.status == 200, 'HTTP failure: ' + path)
            result = json.load(response)
        require(result.get('success') is True, 'API failure: ' + path)
        return result.get('obj')
    csrf = request('csrf-token', bearer=False)
    require(isinstance(csrf,str) and csrf, 'CSRF unavailable')
    request('login', {'username':s['username'],'password':s['password']}, bearer=False, csrf=csrf)
    # Authenticated browser cookies must not hide a broken Bearer-token path.
    cookies.clear()
    if mode == 'api-seed':
        client = {'id':s['uuid'],'email':s['email'],'enable':True,'flow':'','limitIp':0,
                  'totalGB':10737418240,'expiryTime':0,'subId':secrets.token_hex(8),'reset':0}
        inbound = {'enable':True,'remark':'isolated-upgrade-smoke','listen':'127.0.0.1',
            'port':s['inbound_port'],'protocol':'vless','tag':'smoke-vless','up':0,'down':0,
            'total':10737418240,'expiryTime':0,'trafficReset':'never','trafficResetDay':1,
            'settings':{'clients':[client],'decryption':'none'},
            'streamSettings':{'network':'tcp','security':'none'},'sniffing':{'enabled':False}}
        created = request('panel/api/inbounds/add', inbound)
        require(isinstance(created,dict) and created.get('id'), 'Inbound ID missing')
        s['inbound_id'] = created['id']; state_path.write_text(json.dumps(s))
    matches = [row for row in request('panel/api/inbounds/list') if row.get('id') == s['inbound_id']]
    require(len(matches) == 1, 'Seeded inbound missing')
    inbound = matches[0]
    require(inbound.get('tag') == 'smoke-vless' and inbound.get('port') == s['inbound_port'], 'Inbound changed')
    settings = inbound['settings']
    if isinstance(settings,str): settings = json.loads(settings)
    require(any(c.get('id') == s['uuid'] and c.get('email') == s['email'] for c in settings.get('clients',[])), 'Client identity changed')
    if mode == 'api-check':
        require(inbound.get('up') == 1234567 and inbound.get('down') == 7654321, 'Inbound traffic changed')
        matches = [row for row in inbound.get('clientStats',[]) if row.get('email') == s['email']]
        require(len(matches) == 1 and matches[0].get('up') == 112233 and matches[0].get('down') == 445566, 'Client traffic changed')
    deadline = time.monotonic() + 45
    while True:
        status = request('panel/api/server/status')
        if status.get('xray',{}).get('state') == 'running': break
        require(time.monotonic() < deadline, 'Real bundled Xray did not reach running state')
        time.sleep(1)
    require(status.get('panelGuid') == s['guid'], 'Master identity changed')
elif mode == 'seed-traffic':
    s = read_state()
    with connect() as db:
        require(db.execute('UPDATE inbounds SET up=?,down=? WHERE id=?', (1234567,7654321,s['inbound_id'])).rowcount == 1, 'Inbound fixture missing')
        require(db.execute('UPDATE client_traffics SET up=?,down=? WHERE email=?', (112233,445566,s['email'])).rowcount == 1, 'Client fixture missing')
elif mode in ('snapshot','compare'):
    def rows(db, table): return [dict(row) for row in db.execute('SELECT * FROM ' + table + ' ORDER BY id')]
    with connect(True) as db:
        require(db.execute('PRAGMA quick_check').fetchone()[0] == 'ok', 'SQLite integrity failed')
        saved = {t:rows(db,t) for t in ('users','inbounds','client_traffics','api_tokens')}
        saved['nodes'] = [dict(r) for r in db.execute('SELECT id,name,address,port,api_token,enable,traffic_multiplier FROM nodes ORDER BY id')]
        saved['settings'] = [dict(r) for r in db.execute('SELECT key,value FROM settings WHERE key IN (?,?,?,?,?,?,?,?) ORDER BY key',
            ('webPort','webListen','webBasePath','panelGuid','secret','xrayTemplateConfig','subEnable','twoFactorEnable'))]
        for table in ('client_records','client_inbounds'):
            if columns(db,table): saved[table] = [dict(r) for r in db.execute('SELECT * FROM ' + table + ' ORDER BY rowid')]
    for relative in ('install/x-ui','install/bin/xray-linux-amd64','db/node_token_key.json'):
        saved[relative] = digest(root / relative)
    path = root / 'before.json'
    if mode == 'snapshot': path.write_text(json.dumps(saved,sort_keys=True))
    else:
        expected = json.loads(path.read_text())
        for key in expected: require(saved.get(key) == expected[key], 'Preservation mismatch: ' + key)
        backups = list((root / 'backups').glob('backup-*'))
        require(len(backups) == 1, 'Expected one real updater backup')
        require((backups[0] / 'installed-version.txt').read_text().strip() == 'v1.0.0', 'Updater did not complete')
        print('PASS: real master login, API token, inbound/client, traffic, multiplier, key file and Xray checksum preserved')
else: raise RuntimeError('Unknown fixture operation')
PY
python3 "$root/check.py" extract "$root"
port=$(python3 "$root/check.py" init "$root")
[[ $port =~ ^[0-9]+$ ]] || { echo 'Initialization failed.' >&2; exit 1; }
base=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["base"])' "$root/state.json")
[[ ! -e $unit ]] || { echo 'Temporary unit name collision.' >&2; exit 1; }
cat >"$unit" <<UNIT
[Unit]
Description=Isolated Angelo master update smoke test
[Service]
Type=simple
WorkingDirectory=$root/install
ExecStart=$root/install/x-ui
Environment=XUI_DB_TYPE=sqlite
Environment=XUI_DB_FOLDER=$root/db
Environment=XUI_BIN_FOLDER=$root/install/bin
Environment=XUI_LOG_FOLDER=$root/log
Environment=XUI_NODE_TOKEN_KEY_FILE=$root/db/node_token_key.json
Environment=NODE_TOKEN_ENCRYPTION=off
Environment=HOME=$root
Restart=no
TimeoutStartSec=60
TimeoutStopSec=30
KillMode=control-group
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$root
InaccessiblePaths=-/etc/x-ui -/usr/local/x-ui -/var/log/x-ui
PrivateTmp=yes
IPAddressDeny=any
IPAddressAllow=localhost
StandardOutput=append:$root/service.log
StandardError=append:$root/service.log
UNIT
created_unit=1
systemctl daemon-reload
wait_panel() {
    local deadline=$((SECONDS+60)) status
    while ((SECONDS < deadline)); do
        systemctl is-active --quiet "$service" || { echo 'Temporary master exited.' >&2; return 1; }
        status=$(curl -q -s --noproxy '*' --connect-timeout 1 --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port$base") || status=
        [[ $status != 200 ]] || return 0
        sleep 1
    done
    echo 'Temporary master startup timed out.' >&2
    return 1
}
stop_panel() {
    systemctl stop "$service"
    [[ $(systemctl show --property=MainPID --value "$service") == 0 ]] || { echo 'Temporary master did not stop.' >&2; exit 1; }
}
echo 'Starting real systemd master and creating a loopback-only dummy inbound...'
systemctl start "$service"
wait_panel
python3 "$root/check.py" api-seed "$root"
stop_panel
python3 "$root/check.py" seed-traffic "$root"
systemctl start "$service"
wait_panel
python3 "$root/check.py" api-check "$root"
stop_panel
python3 "$root/check.py" snapshot "$root"
systemctl start "$service"
wait_panel
echo 'Running the actual updater against the pinned stable release...'
timeout --signal=TERM --kill-after=45s 360s bash "$script_dir/update-master.sh" \
    --version v1.0.0 --service "$service" --binary "$root/install/x-ui" \
    --backup-root "$root/backups" --health-url "http://127.0.0.1:$port$base" --startup-timeout 60
python3 "$root/check.py" api-check "$root"
stop_panel
python3 "$root/check.py" compare "$root"
echo 'Scope: real pinned v1.0.0 same-version upgrade on SQLite/systemd; no cross-version or encrypted-token-mode claim.'
