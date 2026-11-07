#!/usr/bin/env bash
# No root, service access or network needed: real SQLite/archive fixtures, mocked OS tools.
set -Eeuo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
updater=$script_dir/update-master.sh
root=$(mktemp -d)
fixture_pid=
cleanup() {
    [[ -z $fixture_pid ]] || kill "$fixture_pid" 2>/dev/null || true
    rm -rf -- "$root"
}
trap cleanup EXIT
if [[ -n ${TEST_PYTHON:-} ]]; then
    real_python=$TEST_PYTHON
elif command -v python >/dev/null 2>&1 && python -c 'import sqlite3' >/dev/null 2>&1; then
    real_python=$(command -v python)
else
    real_python=$(command -v python3)
fi
real_readlink=$(command -v readlink)
mkdir "$root/mock"
cat >"$root/mock/python3" <<'SH'
#!/usr/bin/env bash
exec "$TEST_REAL_PYTHON" -c 'import sys,runpy; sys.stdout.reconfigure(newline="\n"); sys.argv=sys.argv[1:]; exec(sys.argv[1]) if sys.argv[0]=="-c" else runpy.run_path(sys.argv[0],run_name="__main__")' "$@"
SH
cat >"$root/mock/id" <<'SH'
#!/usr/bin/env bash
[[ $* == -u ]] || exit 1
printf '0\n'
SH
cat >"$root/mock/uname" <<'SH'
#!/usr/bin/env bash
case $1 in -s) echo Linux ;; -m) echo x86_64 ;; *) exit 1 ;; esac
SH
cat >"$root/mock/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$root/mock/readlink" <<'SH'
#!/usr/bin/env bash
case ${!#} in
    /proc/*/exe) printf '%s\n' "$TEST_CASE/install/x-ui.exe" ;;
    /proc/*/cwd) printf '%s\n' "$TEST_CASE/install" ;;
    *) exec "$TEST_REAL_READLINK" "$@" ;;
esac
SH
cat >"$root/mock/systemctl" <<'SH'
#!/usr/bin/env bash
set -eu
native_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
case $1 in
    is-active) [[ $(cat "$TEST_CASE/active") == 1 ]] ;;
    show)
        if [[ $* == *--property=MainPID* ]]; then
            if [[ $(cat "$TEST_CASE/active") == 1 ]]; then echo "$TEST_FIXTURE_PID"; else echo 0; fi
        elif [[ $* == *--property=EnvironmentFiles* && $* == *--value* ]]; then echo
        elif [[ $* == *'--property=Environment --value'* ]]; then
            folder=$TEST_CASE/db
            [[ $TEST_MODE != environment-drift ]] || folder=$TEST_CASE/wrong-db
            printf 'XUI_DB_FOLDER=%s XUI_DB_TYPE=%s XUI_DB_DSN=%s\n' "$folder" "$TEST_DB_TYPE" "$TEST_DB_DSN"
        elif [[ $* == *'--property=WorkingDirectory --value'* ]]; then
            if [[ $TEST_MODE == cwd-drift ]]; then native_path "$TEST_CASE/other-install"; else native_path "$TEST_CASE/install"; fi
        elif [[ $* == *'--property=ExecStart --value'* ]]; then
            executable=$TEST_CASE/install/x-ui.exe
            [[ $TEST_MODE != exec-drift ]] || executable=$TEST_CASE/different-x-ui
            executable=$(native_path "$executable")
            printf '{ path=%s ; argv[]=%s ; ignore_errors=no ; start_time= ; stop_time= ; pid=0 ; code=(null) ; status=0/0 }\n' "$executable" "$executable"
        elif [[ $* == *--value* ]]; then echo
        else printf 'Environment=SECRET_FOR_BACKUP_ONLY\n'; fi ;;
    cat) printf '[Service]\nExecStart=fixture/x-ui\n' ;;
    stop) echo stop >>"$TEST_CASE/actions"; echo 0 >"$TEST_CASE/active" ;;
    start)
        if cmp -s "$TEST_CASE/install/x-ui.exe" "$TEST_CASE/original"; then
            echo start-old >>"$TEST_CASE/actions"; echo 1 >"$TEST_CASE/active"
        else
            echo start-new >>"$TEST_CASE/actions"
            case $TEST_MODE in
                startup-failure) echo 0 >"$TEST_CASE/active"; exit 1 ;;
                migration-failure)
                    python3 "$TEST_CASE/fixture.py" mutate "$TEST_CASE"
                    echo 0 >"$TEST_CASE/active"; exit 1 ;;
                *) echo 1 >"$TEST_CASE/active" ;;
            esac
        fi ;;
    *) exit 1 ;;
esac
SH
cat >"$root/mock/curl" <<'SH'
#!/usr/bin/env bash
set -eu
out= url=${!#}
while (($#)); do
    case $1 in --output) out=$2; shift 2 ;; *) shift ;; esac
done
case $url in
    https://api.github.com/*) cp "$TEST_CASE/release.json" "$out" ;;
    https://github.com/*/x-ui-linux-amd64.tar.gz) cp "$TEST_CASE/release.tar.gz" "$out" ;;
    https://github.com/*/SHA256SUMS) cp "$TEST_CASE/SHA256SUMS" "$out" ;;
    http://127.0.0.1:2053/*)
        if [[ ${TEST_MODE:-} == unhealthy && $(cat "$TEST_CASE/active") == 1 ]] && ! cmp -s "$TEST_CASE/install/x-ui.exe" "$TEST_CASE/original"; then
            printf 503
        else printf 200; fi ;;
    *) printf 'Mock curl rejected unexpected URL: %s\n' "$url" >&2; exit 22 ;;
esac
SH
chmod +x "$root/mock/"*
cat >"$root/fixture.py" <<'PY'
import hashlib, io, json, os, pathlib, sqlite3, struct, sys, tarfile
mode, root = sys.argv[1], pathlib.Path(sys.argv[2])
if mode == 'mutate':
    with sqlite3.connect(root / 'db/x-ui.db') as db:
        db.execute('CREATE TABLE migrated_schema (id INTEGER)')
        db.execute('UPDATE users SET value=? WHERE key=?', ('new-schema-value', 'alice'))
    sys.exit(0)
if mode == 'assert':
    expected = sys.argv[3]
    def check(path, text): assert (root / path).read_text() == text, path
    check('install/bin/xray-linux-amd64', 'ORIGINAL_XRAY')
    check('install/bin/geoip.dat', 'ORIGINAL_GEODATA')
    check('db/node_token_key.json', 'ORIGINAL_KEY')
    check('db/config.json', 'ORIGINAL_CONFIG')
    check('cert/key.pem', 'PRIVATE_KEY')
    check('cert/cert.pem', 'PUBLIC_CERT')
    with sqlite3.connect(root / 'db/x-ui.db') as db:
        assert db.execute('SELECT value FROM users WHERE key=?', ('alice',)).fetchone()[0] == ('new-schema-value' if expected == 'migration-failure' else 'ORIGINAL_USER')
        assert db.execute('SELECT value FROM traffics').fetchone()[0] == 123456789
        assert db.execute('SELECT value FROM api_tokens').fetchone()[0] == 'ORIGINAL_API_TOKEN'
        assert db.execute('SELECT value FROM inbounds').fetchone()[0] == 'ORIGINAL_INBOUND'
    backups = sorted((root / 'backups').glob('backup-*'))
    if expected in ('success', 'repeat', 'startup-failure', 'unhealthy', 'migration-failure', 'checksums'):
        assert len(backups) == (2 if expected == 'repeat' else 1), backups
        with sqlite3.connect(backups[0] / 'sqlite/x-ui.db') as db:
            assert db.execute('SELECT value FROM users WHERE key=?', ('alice',)).fetchone()[0] == 'ORIGINAL_USER'
        assert (backups[0] / 'sqlite/node_token_key.json').read_text() == 'ORIGINAL_KEY'
        assert (backups[0] / 'installation/bin/xray-linux-amd64').read_text() == 'ORIGINAL_XRAY'
        assert (backups[0] / 'installation/x-ui.exe').read_bytes() == (root / 'original').read_bytes()
        assert (backups[0] / 'service-config/properties.txt').read_text().strip() == 'Environment=SECRET_FOR_BACKUP_ONLY'
        recovery = json.loads((backups[0] / 'recovery.json').read_text())
        assert len(recovery['externalConfig']) == 2, recovery
    else: assert len(backups) == 0
    if expected == 'migration-failure':
        assert (backups[0] / 'sqlite-after-failed-start/x-ui.db').exists()
        assert (root / 'active').read_text().strip() == '0'
        assert 'start-old' not in (root / 'actions').read_text()
    else: assert (root / 'active').read_text().strip() == '1'
    if expected in ('success', 'repeat', 'checksums'):
        assert (root / 'install/x-ui.exe').read_bytes() == (root / 'new').read_bytes()
    else: assert (root / 'install/x-ui.exe').read_bytes() == (root / 'original').read_bytes()
    if expected in ('startup-failure', 'unhealthy'): assert 'start-old' in (root / 'actions').read_text()
    if expected in ('bad-digest', 'no-digest', 'postgres', 'bad-archive', 'invalid-tag', 'environment-drift', 'cwd-drift', 'exec-drift'):
        assert not (root / 'actions').read_text()
    assert not list((root / 'backups').glob('.stage.*'))
    assert not (root / 'install/.angelo-master-update.lock').exists()
    for path in root.glob('run*.log'):
        text = path.read_text()
        for secret in ('ORIGINAL_API_TOKEN', 'ORIGINAL_KEY', 'PRIVATE_KEY', 'SECRET_FOR_BACKUP_ONLY', 'secret-dsn-password'):
            assert secret not in text, (path, secret)
    sys.exit(0)
scenario = sys.argv[3]
for part in ('install/bin','db','cert','backups'): (root / part).mkdir(parents=True, exist_ok=True)
for part, value in {'install/x-ui.exe':'#!/bin/sh\n# OLD_EXECUTABLE\n', 'original':'#!/bin/sh\n# OLD_EXECUTABLE\n', 'install/bin/xray-linux-amd64':'ORIGINAL_XRAY', 'install/bin/geoip.dat':'ORIGINAL_GEODATA', 'db/node_token_key.json':'ORIGINAL_KEY', 'db/config.json':'ORIGINAL_CONFIG', 'cert/key.pem':'PRIVATE_KEY', 'cert/cert.pem':'PUBLIC_CERT', 'active':'1', 'actions':''}.items():
    (root / part).write_text(value)
os.chmod(root / 'install/x-ui.exe', 0o755)
with sqlite3.connect(root / 'db/x-ui.db') as db:
    db.execute('CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)')
    db.executemany('INSERT INTO settings VALUES (?,?)', [('webPort','2053'),('webBasePath','/test/'),('webListen','127.0.0.1'),('webCertFile',''),('webKeyFile',''),('subCertFile',str(root / 'cert/cert.pem')),('subKeyFile',str(root / 'cert/key.pem'))])
    for table, val in [('users','ORIGINAL_USER'),('traffics',123456789),('api_tokens','ORIGINAL_API_TOKEN'),('inbounds','ORIGINAL_INBOUND')]:
        db.execute('CREATE TABLE ' + table + ' (key TEXT PRIMARY KEY, value)')
        db.execute('INSERT INTO ' + table + ' VALUES (?,?)', ('alice',val))
elf = bytearray(64); elf[:6] = b'\x7fELF\x02\x01'; struct.pack_into('<H',elf,16,2); struct.pack_into('<H',elf,18,62)
elf.extend(b'NEW_PANEL_FIXTURE'); (root / 'new').write_bytes(elf)
with tarfile.open(root / 'release.tar.gz','w:gz') as tar:
    panel = tarfile.TarInfo('x-ui/x-ui'); panel.size = len(elf); panel.mode = 0o755
    if scenario == 'bad-archive': panel.type = tarfile.SYMTYPE; panel.linkname = '../../etc/shadow'; panel.size = 0
    tar.addfile(panel, io.BytesIO(elf) if panel.isfile() else None)
    other = b'REPLACE_XRAY_BAD'; member = tarfile.TarInfo('x-ui/bin/xray-linux-amd64'); member.size = len(other); tar.addfile(member, io.BytesIO(other))
    evil = tarfile.TarInfo('../../escape'); evil.size = 4; tar.addfile(evil,io.BytesIO(b'evil'))
digest = hashlib.sha256((root / 'release.tar.gz').read_bytes()).hexdigest()
asset = {'name':'x-ui-linux-amd64.tar.gz','size':(root / 'release.tar.gz').stat().st_size,'digest':'sha256:' + digest,'browser_download_url':'https://github.com/AngeloSakura/Angelo-xui-plugin-2/releases/download/v1.0.0/x-ui-linux-amd64.tar.gz'}
if scenario == 'bad-digest': asset['digest'] = 'sha256:' + '0' * 64
if scenario in ('no-digest','checksums'): asset['digest'] = None
assets = [asset]
if scenario == 'checksums':
    checksum = digest + '  x-ui-linux-amd64.tar.gz\n'; (root / 'SHA256SUMS').write_text(checksum)
    assets.append({'name':'SHA256SUMS','size':len(checksum),'browser_download_url':'https://github.com/AngeloSakura/Angelo-xui-plugin-2/releases/download/v1.0.0/SHA256SUMS'})
(root / 'release.json').write_text(json.dumps({'tag_name':'v1.0.0','draft':False,'prerelease':False,'assets':assets}))
PY
export TEST_REAL_PYTHON=$real_python TEST_REAL_READLINK=$real_readlink
passed=0
for scenario in success repeat startup-failure unhealthy migration-failure bad-digest no-digest checksums postgres bad-archive invalid-tag environment-drift cwd-drift exec-drift; do
    case_dir=$root/$scenario
    mkdir "$case_dir"
    "$real_python" "$root/fixture.py" setup "$case_dir" "$scenario"
    cp "$root/fixture.py" "$case_dir/fixture.py"
    db_type=sqlite dsn=
    [[ $scenario != postgres ]] || { db_type=postgres; dsn=postgres://secret-dsn-password; }
    # A real /proc/PID/environ makes the script exercise runtime DB detection.
    XUI_DB_FOLDER="$case_dir/db" XUI_DB_TYPE=$db_type XUI_DB_DSN=$dsn bash -c 'while :; do sleep 60; done' &
    fixture_pid=$!
    export TEST_CASE=$case_dir TEST_MODE=$scenario TEST_FIXTURE_PID=$fixture_pid TEST_DB_TYPE=$db_type TEST_DB_DSN=$dsn
    tag=v1.0.0; [[ $scenario != invalid-tag ]] || tag='../../latest'
    set +e
    PATH="$root/mock:$PATH" bash "$updater" --version "$tag" --binary "$case_dir/install/x-ui.exe" --backup-root "$case_dir/backups" --startup-timeout 10 >"$case_dir/run.log" 2>&1
    status=$?
    set -e
    if [[ $scenario == success || $scenario == repeat || $scenario == checksums ]]; then
        if ((status != 0)); then cat "$case_dir/run.log"; echo "FAIL: $scenario unexpectedly failed" >&2; exit 1; fi
    else
        if ((status == 0)); then echo "FAIL: $scenario unexpectedly succeeded" >&2; exit 1; fi
    fi
    if [[ $scenario == repeat ]]; then
        PATH="$root/mock:$PATH" bash "$updater" --version v1.0.0 --binary "$case_dir/install/x-ui.exe" --backup-root "$case_dir/backups" --startup-timeout 10 >"$case_dir/run2.log" 2>&1 || { cat "$case_dir/run2.log"; exit 1; }
    fi
    "$real_python" "$root/fixture.py" assert "$case_dir" "$scenario" || { cat "$case_dir/run.log"; exit 1; }
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
    fixture_pid=
    passed=$((passed+1))
    printf 'PASS %s\n' "$scenario"
done
printf '%s master updater regression cases passed.\n' "$passed"
