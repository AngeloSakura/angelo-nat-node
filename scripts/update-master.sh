#!/usr/bin/env bash
# Independent SQLite-backed master updater; no node or Xray installation.
set +x
set -Eeuo pipefail
umask 077
usage() {
    cat <<'USAGE'
Usage: sudo bash scripts/update-master.sh --version v1.0.0 [options]
  --version TAG          Explicit stable release tag (required).
  --service NAME         Existing systemd service (default: x-ui.service).
  --binary PATH          Existing executable (default: /usr/local/x-ui/x-ui).
  --backup-root PATH     Backup directory (default: /var/backups/angelo-master).
  --backup-path PATH     Additional external config/key path; repeatable.
  --health-url URL       Optional local HTTP(S) health URL, without credentials.
  --startup-timeout N    Startup deadline, 10-600 seconds (default: 60).
Requires Linux amd64, root, systemd, curl, Python 3.8+ with sqlite3.
USAGE
}
log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need_value() { [[ $# -ge 2 && -n $2 && $2 != --* ]] || die "Missing value for $1"; }
version= service=x-ui.service binary=/usr/local/x-ui/x-ui
backup_root=/var/backups/angelo-master health_override= startup_timeout=60
declare -a extra_paths=()
while (($#)); do
    case $1 in
        --version) need_value "$@"; version=$2; shift 2 ;;
        --service) need_value "$@"; service=$2; shift 2 ;;
        --binary) need_value "$@"; binary=$2; shift 2 ;;
        --backup-root) need_value "$@"; backup_root=$2; shift 2 ;;
        --backup-path) need_value "$@"; extra_paths+=("$2"); shift 2 ;;
        --health-url) need_value "$@"; health_override=$2; shift 2 ;;
        --startup-timeout) need_value "$@"; startup_timeout=$2; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die 'Unknown option; use --help' ;;
    esac
done
[[ $version =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || die 'Supply an explicit stable tag, such as --version v1.0.0'
[[ $service =~ ^[A-Za-z0-9_][A-Za-z0-9_.@-]*\.service$ ]] || die 'Invalid service name; include .service'
[[ $startup_timeout =~ ^[0-9]+$ && ${#startup_timeout} -le 3 ]] || die 'Invalid timeout'
startup_timeout=$((10#$startup_timeout))
((startup_timeout >= 10 && startup_timeout <= 600)) || die 'Timeout must be 10-600 seconds'
[[ $(uname -s) == Linux ]] || die 'Linux/systemd required'
[[ $(uname -m) == x86_64 || $(uname -m) == amd64 ]] || die 'Master releases support linux/amd64 only'
[[ $(id -u) == 0 ]] || die 'Run as root'
for command in python3 curl systemctl realpath readlink mktemp cp chmod mv mkdir rm rmdir cmp; do
    command -v "$command" >/dev/null 2>&1 || die "Required command unavailable: $command"
done
python3 -c 'import sys,sqlite3,tarfile; assert sys.version_info >= (3,8)' >/dev/null 2>&1 || die 'Python 3.8+ with sqlite3 required on the master'
[[ $binary == /* && $backup_root == /* ]] || die 'Executable and backup paths must be absolute'
[[ ! -L $binary && -f $binary && -x $binary ]] || die 'Existing executable must be regular, executable and not a symlink'
binary=$(realpath -e -- "$binary")
install_dir=${binary%/*}
[[ $install_dir != / ]] || die 'Refusing executable directly below /'
backup_root=$(realpath -m -- "$backup_root")
[[ $backup_root != / && $backup_root != "$install_dir" && $backup_root != "$install_dir/"* ]] || die 'Backup root must be outside installation directory'
mkdir -p -- "$backup_root"
chmod 700 -- "$backup_root"
lock_dir=$install_dir/.angelo-master-update.lock
mkdir -- "$lock_dir" 2>/dev/null || die 'An update holds the lock; inspect it before removing a stale lock'
printf '%s\n' "$$" >"$lock_dir/pid"
stage= backup= stopped=0 rollback_required=0 installed_ok=0
finish() {
    local code=$? current_fingerprint= restart_old=0
    trap - EXIT INT TERM
    set +e
    if ((rollback_required && !installed_ok)); then
        log 'Update failed. Stopping the master and restoring the old executable.'
        systemctl stop "$service" >/dev/null 2>&1
        if systemctl is-active --quiet "$service" || [[ $(systemctl show --property=MainPID --value "$service" 2>/dev/null) != 0 ]]; then
            log 'CRITICAL: service did not stop; file rollback refused. Inspect service and private backup.'
        elif python3 "$stage/helper.py" replace "$backup/installation/${binary##*/}" "$binary" >/dev/null 2>&1; then
            if python3 "$stage/helper.py" failed-state "$db_dir" "$backup" >/dev/null 2>&1; then
                current_fingerprint=$(python3 "$stage/helper.py" fingerprint "$db_dir/x-ui.db" 2>/dev/null)
                [[ -z $current_fingerprint || $current_fingerprint != "$before_fingerprint" ]] || restart_old=1
            fi
            if ((restart_old)); then
                if systemctl start "$service" >/dev/null 2>&1 && wait_healthy; then
                    log 'Previous executable restored and healthy; SQLite content is unchanged.'
                else
                    systemctl stop "$service" >/dev/null 2>&1
                    log 'Old executable restored, but health check failed. Service left stopped.'
                fi
            else
                log 'Old executable restored. SQLite changed or could not be checked: service left stopped for recovery review.'
                log 'Pre-update and failed-start SQLite copies retained. No database was automatically restored.'
            fi
        else
            log 'CRITICAL: executable rollback failed; service left stopped. Recover executable from backup.'
        fi
        code=1
    elif ((stopped && !installed_ok)); then
        systemctl start "$service" >/dev/null 2>&1 || log 'Original executable unchanged, but original service could not restart.'
        code=1
    fi
    [[ -z $backup ]] || log "Private recovery backup: $backup"
    if [[ -n $stage && $stage == "$backup_root/.stage."* ]]; then rm -rf -- "$stage"; fi
    rm -f -- "$lock_dir/pid"
    rmdir -- "$lock_dir" 2>/dev/null
    exit "$code"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stage=$(mktemp -d "$backup_root/.stage.XXXXXXXX")
cat >"$stage/helper.py" <<'PY'
import hashlib, ipaddress, json, os, pathlib, re, shlex, shutil, sqlite3, stat, struct, sys, tarfile, tempfile
from urllib.parse import quote, urlsplit
REPO = 'AngeloSakura/Angelo-xui-plugin-2'
ASSET = 'x-ui-linux-amd64.tar.gz'
def fail(message):
    raise ValueError(message)
def db_open(path):
    return sqlite3.connect(pathlib.Path(path).resolve().as_uri() + '?mode=ro', uri=True, timeout=10)
def fingerprint(path):
    with db_open(path) as db:
        if db.execute('PRAGMA quick_check').fetchall() != [('ok',)]: fail('SQLite integrity check failed')
        h = hashlib.sha256()
        for statement in db.iterdump():
            h.update(statement.encode('utf-8')); h.update(b'\x00')
        return h.hexdigest()
def safe_path(path, cwd):
    if not path or any(c in path for c in '\x00\n\r'): fail('Invalid configuration path')
    return os.path.normpath(path if os.path.isabs(path) else os.path.join(cwd, path))
def release(path, tag):
    with open(path, encoding='utf-8') as f: data = json.load(f)
    if data.get('tag_name') != tag or data.get('draft') or data.get('prerelease'): fail('Requested stable release not found')
    assets = data.get('assets', [])
    found = [a for a in assets if a.get('name') == ASSET]
    if len(found) != 1: fail('Expected exactly one linux/amd64 archive')
    a = found[0]
    prefix = 'https://github.com/' + REPO + '/releases/download/' + quote(tag, safe='') + '/'
    if a.get('browser_download_url') != prefix + ASSET: fail('Unexpected release asset URL')
    if not isinstance(a.get('size'), int) or not 0 < a['size'] <= 512 * 1024 * 1024: fail('Archive size missing or too large')
    digest = a.get('digest') or ''
    if digest:
        if not re.fullmatch(r'sha256:[0-9a-fA-F]{64}', digest): fail('Unsupported asset digest')
        print(a['browser_download_url']); print(digest[7:].lower()); print(''); print(a['size']); return
    for name in (ASSET + '.sha256', 'SHA256SUMS', 'SHA256SUMS.txt', 'sha256sums.txt', 'checksums.txt'):
        matches = [x for x in assets if x.get('name') == name]
        if len(matches) == 1 and matches[0].get('browser_download_url') == prefix + name:
            if not isinstance(matches[0].get('size'), int) or not 0 < matches[0]['size'] <= 1024 * 1024: fail('Checksum asset too large')
            print(a['browser_download_url']); print(''); print(prefix + name); print(a['size']); return
    fail('Release has neither GitHub SHA256 digest nor a supported published checksum; refusing update')
def checksum(path, detached):
    matches = []
    for line in pathlib.Path(path).read_text(encoding='utf-8').splitlines():
        m = re.fullmatch(r'([0-9a-fA-F]{64})\s+\*?(?:\./)?' + re.escape(ASSET), line.strip())
        if m: matches.append(m[1].lower())
        elif detached and re.fullmatch(r'[0-9a-fA-F]{64}', line.strip()): matches.append(line.strip().lower())
    if len(matches) != 1: fail('Checksum must identify this exact archive once')
    print(matches[0])
def extract(archive, digest, size, destination):
    if os.path.getsize(archive) != int(size): fail('Downloaded archive size differs from release metadata')
    h = hashlib.sha256()
    with open(archive, 'rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''): h.update(block)
    if h.hexdigest() != digest: fail('SHA256 verification failed; installation is untouched')
    # Stream through the archive to avoid retaining a maliciously large member list.
    found = False
    with tarfile.open(archive, 'r|gz') as tar:
        for m in tar:
            if m.name not in ('x-ui/x-ui', './x-ui/x-ui'): continue
            if found or not m.isfile() or not 64 <= m.size <= 128 * 1024 * 1024: fail('Invalid or duplicate panel executable')
            found = True
            with tar.extractfile(m) as src, open(destination, 'xb') as dst: shutil.copyfileobj(src, dst, 1024 * 1024)
    if not found: fail('Archive has no x-ui/x-ui executable')
    with open(destination, 'rb') as f: header = f.read(64)
    if header[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', header, 18)[0] != 62 or struct.unpack_from('<H', header, 16)[0] not in (2, 3):
        fail('Archive member is not an amd64 ELF executable')
    os.chmod(destination, 0o755)
def unit_paths(path):
    raw = pathlib.Path(path).read_text(encoding='utf-8').strip()
    while raw:
        m = re.match(r'(.+?) \(ignore_errors=(yes|no)\)(?: |$)', raw)
        if not m or not m[1].startswith('/') or any(c in m[1] for c in '\n\r\\'): fail('Unsupported systemd EnvironmentFiles format')
        if os.path.isfile(m[1]): print(m[1])
        elif m[2] != 'yes': fail('Required systemd environment file missing')
        raw = raw[m.end():]
def config_guard(stage):
    stage = pathlib.Path(stage)
    critical = {'XUI_DB_TYPE','XUI_DB_FOLDER','XUI_DB_DSN','XUI_NODE_TOKEN_KEY_FILE','XUI_NODE_TOKEN_KEY','NODE_TOKEN_ENCRYPTION','XUI_BIN_FOLDER'}
    values = {}
    raw = (stage / 'unit-environment.txt').read_text(encoding='utf-8')
    for token in shlex.split(raw):
        if '=' not in token: fail('Unsupported systemd environment')
        key, val = token.split('=', 1); values[key] = val
    files = [p for p in (stage / 'environment-paths.txt').read_text(encoding='utf-8').splitlines() if p]
    hashes = []
    for path in files:
        payload = pathlib.Path(path).read_bytes(); hashes.append((path,hashlib.sha256(payload).hexdigest()))
        for line in payload.decode('utf-8').splitlines():
            line = line.strip()
            if not line or line.startswith(('#',';')): continue
            key, sep, val = line.partition('='); key = key.strip()
            if key not in critical: continue
            if not sep or val.endswith('\\') or '\x00' in val: fail('Complex service environment requires manual review')
            parts = shlex.split(val, comments=False)
            if len(parts) > 1: fail('Complex service environment requires manual review')
            values[key] = parts[0] if parts else ''
    running = {}
    for item in (stage / 'process-environment.bin').read_bytes().split(b'\x00'):
        if b'=' in item:
            key, val = item.split(b'=',1); running[key.decode()] = val.decode()
    if any(values.get(key, '') != running.get(key, '') for key in critical):
        fail('Saved service database/key environment differs from the running master; reconcile and restart it before update')
    # A private fingerprint detects file changes during staging without leaking values.
    print(hashlib.sha256(json.dumps(hashes,sort_keys=True).encode()).hexdigest())
def service_guard(stage, binary, cwd):
    stage = pathlib.Path(stage)
    directory = (stage / 'loaded-working-directory.txt').read_text(encoding='utf-8').strip() or '/'
    if not os.path.isabs(directory) or any(c in directory for c in '\n\r\\'):
        fail('Unsupported loaded systemd WorkingDirectory; review service before update')
    if os.path.realpath(directory) != os.path.realpath(cwd):
        fail('Loaded systemd WorkingDirectory differs from the running master; reconcile and restart before update')
    command = (stage / 'loaded-exec-start.txt').read_text(encoding='utf-8').strip()
    if command.count('{') != 1 or command.count('}') != 1:
        fail('Expected one direct systemd ExecStart command')
    match = re.fullmatch(r'\{\s*path=(.*?)\s*;\s*argv\[\]=(.*?)\s*;\s*ignore_errors=(?:yes|no)\s*;.*\}', command, re.S)
    if not match or any(c in match[1] + match[2] for c in '\n\r\\'):
        fail('Unsupported loaded systemd ExecStart; review service before update')
    path, arguments = match[1].strip(), shlex.split(match[2].strip())
    if not os.path.isabs(path) or os.path.realpath(path) != os.path.realpath(binary) or arguments != [path]:
        fail('Loaded systemd ExecStart differs from the running master executable or adds arguments; reconcile and restart before update')
def health(path, override):
    with db_open(path) as db: settings = dict(db.execute('SELECT key,value FROM settings'))
    if override:
        u = urlsplit(override)
        if u.scheme not in ('http', 'https') or u.username or u.password or u.query or u.fragment or any(c in override for c in '\n\r'):
            fail('Health URL must be HTTP(S) without credentials, query or fragment')
        try: local = ipaddress.ip_address(u.hostname).is_loopback
        except (ValueError, TypeError): local = u.hostname == 'localhost'
        if not local: fail('Health override must use a loopback address')
        print(override); print(''); return
    host = (settings.get('webListen') or '').strip()
    if host in ('', '0.0.0.0'): host = '127.0.0.1'
    elif host == '::': host = '::1'
    try: address = ipaddress.ip_address(host)
    except ValueError: fail('Unsupported webListen; provide --health-url')
    port = int(settings.get('webPort') or 2053)
    if not 1 <= port <= 65535: fail('Invalid panel port')
    base = settings.get('webBasePath') or '/'
    if not base.startswith('/'): base = '/' + base
    if not base.endswith('/'): base += '/'
    if any(c in base for c in '\n\r?#'): fail('Unsupported panel base path')
    scheme = 'https' if settings.get('webCertFile') and settings.get('webKeyFile') else 'http'
    domain = (settings.get('webDomain') or '').strip()
    if any(c in domain for c in '\n\r'): fail('Invalid panel domain')
    print(f'{scheme}://[{host}]:{port}{base}' if address.version == 6 else f'{scheme}://{host}:{port}{base}'); print(domain)
def backup(db_dir, install_dir, destination, cwd, paths_file, stage, tag, digest):
    if os.path.islink(os.path.join(db_dir, 'x-ui.db')): fail('Symlinked SQLite unsupported')
    os.makedirs(destination, mode=0o700, exist_ok=False)
    # Whole SQLite directory: DB, WAL, SHM, journal, keys, configuration.
    shutil.copytree(db_dir, os.path.join(destination, 'sqlite'), symlinks=True)
    shutil.copytree(install_dir, os.path.join(destination, 'installation'), symlinks=True)
    shutil.copytree(os.path.join(stage, 'service-config'), os.path.join(destination, 'service-config'), symlinks=True)
    paths = [p for p in pathlib.Path(paths_file).read_text(encoding='utf-8').split('\n') if p]
    with db_open(os.path.join(db_dir, 'x-ui.db')) as db:
        settings = dict(db.execute('SELECT key,value FROM settings'))
        for key in ('webCertFile', 'webKeyFile', 'subCertFile', 'subKeyFile'):
            if settings.get(key): paths.append(safe_path(settings[key], cwd))
        def walk(value):
            if isinstance(value, dict):
                for key, val in value.items():
                    if key in ('certificateFile', 'keyFile', 'certFile', 'privateKeyFile', 'publicKeyFile') and isinstance(val, str) and val:
                        paths.append(safe_path(val, cwd))
                    else: walk(val)
            elif isinstance(value, list):
                for val in value: walk(val)
        for value in settings.values():
            try: parsed = json.loads(value)
            except (ValueError, TypeError): continue
            walk(parsed)
        columns = {r[1] for r in db.execute('PRAGMA table_info(inbounds)')}
        for column in ('settings', 'stream_settings'):
            if column not in columns: continue
            for (value,) in db.execute('SELECT ' + column + ' FROM inbounds'):
                try: parsed = json.loads(value)
                except (ValueError, TypeError): continue
                walk(parsed)
    index = []; external_dir = os.path.join(destination, 'external-config'); os.mkdir(external_dir, 0o700)
    for i, source in enumerate(dict.fromkeys(paths)):
        if not os.path.isabs(source) or not os.path.exists(source): fail('External backup path missing or not absolute')
        resolved = os.path.realpath(source)
        if os.path.commonpath([resolved, destination]) == resolved: fail('External backup path contains backup destination')
        target = os.path.join(external_dir, str(i))
        if os.path.isdir(source): shutil.copytree(source, target, symlinks=False)
        elif os.path.isfile(source): shutil.copy2(source, target, follow_symlinks=True)
        else: fail('External configuration is not a regular file/directory')
        index.append({'source': source, 'backup': 'external-config/' + str(i)})
    result = fingerprint(os.path.join(destination, 'sqlite', 'x-ui.db'))
    with open(os.path.join(destination, 'recovery.json'), 'w', encoding='utf-8') as f:
        json.dump({'release':tag, 'archiveSha256':digest, 'databaseFingerprint':result, 'databaseDirectory':db_dir, 'installationDirectory':install_dir, 'externalConfig':index}, f, indent=2)
    print(result)
def replace(source, target):
    original = os.stat(target, follow_symlinks=False)
    if not stat.S_ISREG(original.st_mode): fail('Executable target is not a regular file')
    fd, pending = tempfile.mkstemp(prefix='.x-ui.update.', dir=os.path.dirname(target))
    try:
        with os.fdopen(fd, 'wb') as dst, open(source, 'rb') as src:
            shutil.copyfileobj(src, dst, 1024 * 1024); dst.flush(); os.fsync(dst.fileno())
        # Keep timestamps/mode and supported xattrs, including SELinux context.
        shutil.copystat(target, pending, follow_symlinks=False)
        os.chmod(pending, stat.S_IMODE(original.st_mode) & 0o777)
        if hasattr(os, 'chown'): os.chown(pending, original.st_uid, original.st_gid)
        os.replace(pending, target)
        if os.name != 'nt':
            fd = os.open(os.path.dirname(target), os.O_RDONLY)
            try: os.fsync(fd)
            finally: os.close(fd)
    finally:
        if os.path.exists(pending): os.unlink(pending)
def main():
    mode, args = sys.argv[1], sys.argv[2:]
    if mode == 'release': release(*args)
    elif mode == 'checksum': checksum(args[0], args[1] == '1')
    elif mode == 'extract': extract(*args)
    elif mode == 'unit-paths': unit_paths(*args)
    elif mode == 'health': health(*args)
    elif mode == 'config-guard': config_guard(*args)
    elif mode == 'service-guard': service_guard(*args)
    elif mode == 'backup': backup(*args)
    elif mode == 'replace': replace(*args)
    elif mode == 'fingerprint': print(fingerprint(args[0]))
    elif mode == 'failed-state': shutil.copytree(args[0], os.path.join(args[1], 'sqlite-after-failed-start'), symlinks=True)
    else: fail('Unknown helper mode')
try: main()
except Exception as error:
    # Never output DB content, environment values, HTTP bodies or credentials.
    print('ERROR: ' + str(error) if isinstance(error, ValueError) else 'ERROR: updater helper failed (' + type(error).__name__ + '); inspect private backup and permissions', file=sys.stderr)
    sys.exit(1)
PY
systemctl is-active --quiet "$service" || die 'Existing master must be running before update'
pid=$(systemctl show --property=MainPID --value "$service")
[[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/environ ]] || die 'Cannot inspect running master environment'
[[ $(readlink -f -- "/proc/$pid/exe") == "$binary" ]] || die 'Service MainPID does not directly run the specified executable'
working_dir=$(readlink -f -- "/proc/$pid/cwd")
db_dir=/etc/x-ui db_type=sqlite db_dsn_present=0 key_file=/etc/x-ui/node_token_key.json
while IFS= read -r -d '' entry; do
    case $entry in
        XUI_DB_TYPE=*) db_type=${entry#*=} ;;
        XUI_DB_FOLDER=*) [[ -z ${entry#*=} ]] || db_dir=${entry#*=} ;;
        XUI_DB_DSN=*) [[ -z ${entry#*=} ]] || db_dsn_present=1 ;;
        XUI_NODE_TOKEN_KEY_FILE=*) [[ -z ${entry#*=} ]] || key_file=${entry#*=} ;;
    esac
done <"/proc/$pid/environ"
unset entry
db_type=${db_type,,}
[[ $db_type == sqlite || -z $db_type ]] && ((db_dsn_present == 0)) || die 'PostgreSQL/unknown database refused. Prepare a tested pg_dump/restore and migration plan; see docs/MASTER-UPDATE.md. Service unchanged.'
[[ $db_dir == /* ]] || db_dir=$working_dir/$db_dir
db_dir=$(realpath -e -- "$db_dir")
[[ -f $db_dir/x-ui.db && ! -L $db_dir/x-ui.db ]] || die 'SQLite database missing or symlinked'
[[ $db_dir != / && $backup_root != "$db_dir" && $backup_root != "$db_dir/"* ]] || die 'Backup root must be outside SQLite directory'
[[ $install_dir != "$db_dir" && $install_dir != "$db_dir/"* && $db_dir != "$install_dir/"* ]] || die 'Overlapping install/database directories need a manual backup plan'
for value in "$db_dir" "$install_dir" "$working_dir" "$backup_root" "$key_file" "${extra_paths[@]}"; do
    [[ $value != *$'\n'* && $value != *$'\r'* ]] || die 'Newlines unsupported in paths'
done
mkdir "$stage/service-config"
systemctl cat "$service" >"$stage/service-config/unit.txt"
systemctl show --property=Environment --property=EnvironmentFiles --property=ExecStart --property=WorkingDirectory --property=FragmentPath --property=DropInPaths "$service" >"$stage/service-config/properties.txt"
systemctl show --property=EnvironmentFiles --value "$service" >"$stage/environment-files.txt"
systemctl show --property=Environment --value "$service" >"$stage/unit-environment.txt"
systemctl show --property=WorkingDirectory --value "$service" >"$stage/loaded-working-directory.txt"
systemctl show --property=ExecStart --value "$service" >"$stage/loaded-exec-start.txt"
python3 "$stage/helper.py" service-guard "$stage" "$binary" "$working_dir"
for property in PassEnvironment UnsetEnvironment RootDirectory RootImage; do
    [[ -z $(systemctl show --property="$property" --value "$service") ]] || die 'Custom service environment/root isolation needs a manual update plan'
done
cp -- "/proc/$pid/environ" "$stage/process-environment.bin"
python3 "$stage/helper.py" unit-paths "$stage/environment-files.txt" >"$stage/environment-paths.txt"
config_fingerprint=$(python3 "$stage/helper.py" config-guard "$stage")
cp -- "$stage/environment-paths.txt" "$stage/paths.txt"
[[ $key_file == /* ]] || key_file=$working_dir/$key_file
[[ ! -e $key_file ]] || printf '%s\n' "$key_file" >>"$stage/paths.txt"
for value in "${extra_paths[@]}"; do
    [[ $value == /* && -e $value ]] || die 'Extra backup paths must be existing absolute paths'
    value=$(realpath -e -- "$value")
    [[ $value != / && $backup_root != "$value" && $backup_root != "$value/"* ]] || die 'Extra backup path contains backup root'
    printf '%s\n' "$value" >>"$stage/paths.txt"
done
python3 "$stage/helper.py" health "$db_dir/x-ui.db" "$health_override" >"$stage/health.txt"
mapfile -t health_fields <"$stage/health.txt"
health_url=${health_fields[0]} health_host=${health_fields[1]:-}
health_once() {
    local status
    local -a args=(-q --silent --insecure --noproxy '*' --connect-timeout 2 --max-time 3 --output /dev/null --write-out '%{http_code}')
    [[ -z $health_host ]] || args+=(--header "Host: $health_host")
    status=$(curl "${args[@]}" -- "$health_url" 2>/dev/null) || return 1
    [[ $status == 200 ]]
}
wait_healthy() {
    local stable=0 last_pid= current_pid= deadline=$((SECONDS+startup_timeout))
    while ((SECONDS < deadline)); do
        current_pid=$(systemctl show --property=MainPID --value "$service" 2>/dev/null) || current_pid=
        if [[ $current_pid =~ ^[1-9][0-9]*$ ]] && systemctl is-active --quiet "$service" && health_once; then
            if [[ $current_pid == "$last_pid" ]]; then stable=$((stable+1)); else stable=1; fi
            ((stable < 10)) || return 0
        else stable=0; fi
        last_pid=$current_pid
        sleep 1
    done
    return 1
}
health_once || die 'Existing local health check failed; fix it or supply --health-url before upgrading'
fetch() {
    curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 900 --retry 2 --max-filesize "$3" --output "$2" -- "$1"
}
log "Verifying master release $version from AngeloSakura/Angelo-xui-plugin-2..."
fetch "https://api.github.com/repos/AngeloSakura/Angelo-xui-plugin-2/releases/tags/$version" "$stage/release.json" 2097152
python3 "$stage/helper.py" release "$stage/release.json" "$version" >"$stage/release-fields.txt"
mapfile -t release_fields <"$stage/release-fields.txt"
asset_url=${release_fields[0]} expected_sha=${release_fields[1]} checksum_url=${release_fields[2]} archive_size=${release_fields[3]}
if [[ -z $expected_sha ]]; then
    fetch "$checksum_url" "$stage/checksums.txt" 1048576
    detached=0; [[ $checksum_url != */x-ui-linux-amd64.tar.gz.sha256 ]] || detached=1
    expected_sha=$(python3 "$stage/helper.py" checksum "$stage/checksums.txt" "$detached")
fi
fetch "$asset_url" "$stage/release.tar.gz" "$archive_size"
python3 "$stage/helper.py" extract "$stage/release.tar.gz" "$expected_sha" "$archive_size" "$stage/x-ui"
[[ $(systemctl show --property=MainPID --value "$service") == "$pid" ]] || die 'Master restarted during staging; rerun update'
[[ $(readlink -f -- "/proc/$pid/exe") == "$binary" ]] || die 'Master executable changed during staging'
systemctl cat "$service" >"$stage/unit-current.txt"
systemctl show --property=Environment --property=EnvironmentFiles --property=ExecStart --property=WorkingDirectory --property=FragmentPath --property=DropInPaths "$service" >"$stage/properties-current.txt"
cmp -s "$stage/unit-current.txt" "$stage/service-config/unit.txt" && cmp -s "$stage/properties-current.txt" "$stage/service-config/properties.txt" || die 'Service configuration changed during staging; rerun update'
systemctl show --property=WorkingDirectory --value "$service" >"$stage/loaded-working-directory.txt"
systemctl show --property=ExecStart --value "$service" >"$stage/loaded-exec-start.txt"
python3 "$stage/helper.py" service-guard "$stage" "$binary" "$working_dir"
[[ $(python3 "$stage/helper.py" config-guard "$stage") == "$config_fingerprint" ]] || die 'Service environment file changed during staging; rerun update'
log 'Archive verified. Stopping master for a complete SQLite/configuration backup.'
stopped=1
systemctl stop "$service" >/dev/null
if systemctl is-active --quiet "$service"; then die 'Master did not stop; executable unchanged'; fi
[[ $(systemctl show --property=MainPID --value "$service") == 0 ]] || die 'Master process remains after stop; executable unchanged'
backup=$backup_root/backup-$(date -u +%Y%m%dT%H%M%SZ)-$$
before_fingerprint=$(python3 "$stage/helper.py" backup "$db_dir" "$install_dir" "$backup" "$working_dir" "$stage/paths.txt" "$stage" "$version" "$expected_sha")
cp -- "$stage/release.json" "$backup/release.json"
rollback_required=1
python3 "$stage/helper.py" replace "$stage/x-ui" "$binary"
log 'Only panel executable replaced. Checking the restarted master.'
systemctl start "$service" >/dev/null
wait_healthy || die 'Updated master did not remain healthy for ten checks'
installed_ok=1
printf '%s\n' "$version" >"$backup/installed-version.txt"
log "Master update to $version completed. Existing database retains users, traffic, keys and settings."
log 'Bundled Xray, geodata, service configuration and NAT nodes were not replaced.'
