#!/usr/bin/env bash
# Isolated filesystem and mocked systemd/network test for the one-time migration.
set -Eeuo pipefail
[[ $(uname -s) == Linux ]] || { echo 'Linux required' >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d "${TMPDIR:-/tmp}/angelo-migration-tests.XXXXXXXX")
trap 'rm -rf -- "$root"' EXIT
original_path=$PATH
fail() { printf 'FAIL: %s\n' "$*" >&2; [[ ! -f ${case_dir:-}/output ]] || cat "$case_dir/output" >&2; exit 1; }
same() { cmp -s -- "$1" "$2" || fail "Changed: $1"; }

create_case() {
 case_dir=$root/$1
 mkdir -p "$case_dir/bin" "$case_dir/install" "$case_dir/etc" "$case_dir/state" "$case_dir/releases" "$case_dir/package" "$case_dir/tmp" "$case_dir/proc/123"
 export TEST_CASE=$case_dir TEST_MODE=success TEST_STATE_DIR=$case_dir/state TMPDIR=$case_dir/tmp PATH=$case_dir/bin:$original_path
 printf 'active\n' >"$case_dir/service-status"
 : >"$case_dir/service-log"
 : >"$case_dir/network-log"
 printf '{"token":"private-do-not-print","stateDir":"%s"}\n' "$TEST_STATE_DIR" >"$case_dir/etc/config.json"
 printf '{"users":["alice"],"up":100,"down":200}\n' >"$case_dir/state/state.json"
 printf 'unchanged Xray binary bytes\n' >"$case_dir/install/xray"
 printf 'x-ui\n' >"$case_dir/proc/123/comm"
 cat >"$case_dir/template" <<'NODE'
#!/bin/sh
set -eu
version=VERSION_MARKER
mode=
while [ "$#" -gt 0 ]; do
 case "$1" in
  -config) shift 2;;
  -version|-check|-health-check|-state-dir-path) mode=$1;shift;;
  *) exit 20;;
 esac
done
case "$mode" in
 -version) echo "$version";;
 -state-dir-path) echo "$TEST_STATE_DIR";;
 -check) [ -f "$TEST_STATE_DIR/state.json" ];;
 -health-check)
  [ -f "$TEST_STATE_DIR/state.json" ] || exit 21
  if [ "$version" = v0.1.1 ] && [ "$TEST_MODE" = failed-health ]; then exit 22; fi;;
 *) exit 23;;
esac
NODE
 sed 's/VERSION_MARKER/v0.1.0/' "$case_dir/template" >"$case_dir/install/angelo-node"
 sed 's/VERSION_MARKER/v0.1.1/' "$case_dir/template" >"$case_dir/package/x-ui"
 chmod 755 "$case_dir/install/angelo-node" "$case_dir/package/x-ui"
 printf '[Unit]\nDescription=Test node\n[Service]\nExecStart=%s/install/angelo-node -config %s/etc/config.json\n' "$case_dir" "$case_dir" >"$case_dir/etc/angelo-node.service"
 cp "$case_dir/state/state.json" "$case_dir/expected-state"
 cp "$case_dir/etc/config.json" "$case_dir/expected-config"
 cp "$case_dir/install/xray" "$case_dir/expected-xray"
 cp "$case_dir/etc/angelo-node.service" "$case_dir/expected-unit"
 cat >"$case_dir/bin/id" <<'MOCK'
#!/bin/sh
[ "$*" = -u ] && echo 0
MOCK
 cat >"$case_dir/bin/install" <<'MOCK'
#!/bin/sh
for last; do :; done
if [ "$TEST_MODE" = partial-install ] && [ "$last" = "$TEST_CASE/install/x-ui" ]; then
 printf 'partial executable\n' >"$last"
 exit 40
fi
exec /usr/bin/install "$@"
MOCK
 cat >"$case_dir/bin/mv" <<'MOCK'
#!/bin/sh
for last; do :; done
if [ "$TEST_MODE" = failed-unit-move ] && [ "$last" = "$TEST_CASE/etc/angelo-node.service" ]; then exit 41; fi
exec /usr/bin/mv "$@"
MOCK
 cat >"$case_dir/bin/curl" <<'MOCK'
#!/bin/sh
set -eu
out= url=
while [ "$#" -gt 0 ]; do
 case "$1" in -o) out=$2;shift 2;; --retry|--connect-timeout|--max-filesize) shift 2;; https://*) url=$1;shift;; *) shift;; esac
done
printf '%s\n' "$url" >>"$TEST_CASE/network-log"
case "$url" in
 */v0.1.1/SHA256SUMS) cp "$TEST_CASE/releases/SHA256SUMS" "$out";;
 */v0.1.1/angelo-node-linux-amd64.tar.gz) cp "$TEST_CASE/releases/angelo-node-linux-amd64.tar.gz" "$out";;
 *) exit 24;;
esac
MOCK
 cat >"$case_dir/bin/systemctl" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$TEST_CASE/service-log"
case "$1" in
 show)
  case "$*" in
   *'--property=FragmentPath'*) echo "$TEST_CASE/etc/angelo-node.service";;
   *'--property=ExecStart'*) program=$(awk -F'[ =]' '/^ExecStart=/ {print $2}' "$TEST_CASE/etc/angelo-node.service");printf '{ path=%s ; argv[]=%s ; }\n' "$program" "$program";;
   *'--property=MainPID'*) echo 123;;
   *) exit 25;;
  esac;;
 is-active) [ "$(cat "$TEST_CASE/service-status")" = active ];;
 stop) echo inactive >"$TEST_CASE/service-status";;
 start) echo active >"$TEST_CASE/service-status";;
 daemon-reload) :;;
 *) exit 26;;
esac
MOCK
 chmod 755 "$case_dir/bin/"*
 python3 - "$repo/scripts/migrate-v0.1.0.sh" "$case_dir/migrate.sh" "$case_dir" <<'PY'
import pathlib, sys
source, output, case = sys.argv[1:]
text = pathlib.Path(source).read_text()
replacements = {
    '/usr/local/bin/angelo-node': case + '/install/angelo-node',
    '/usr/local/bin/x-ui': case + '/install/x-ui',
    '/etc/angelo-node/config.json': case + '/etc/config.json',
    '/etc/systemd/system/angelo-node.service': case + '/etc/angelo-node.service',
    '/var/backups/angelo-node': case + '/backups',
    '/proc/$pid/': case + '/proc/$pid/',
    '$(date +%s) + 30': '$(date +%s) + 1',
}
for old, new in replacements.items():
    assert old in text, old
    text = text.replace(old, new)
pathlib.Path(output).write_text(text)
PY
 tar -czf "$case_dir/releases/angelo-node-linux-amd64.tar.gz" -C "$case_dir/package" x-ui
 (cd "$case_dir/releases"; sha256sum angelo-node-linux-amd64.tar.gz >SHA256SUMS)
 ln -s "$case_dir/install/x-ui" "$case_dir/proc/123/exe"
}

run_case() {
 local want=$1 rc=0
 sh "$case_dir/migrate.sh" >"$case_dir/output" 2>&1 || rc=$?
 if [[ $want == pass ]]; then [[ $rc == 0 ]] || fail "expected migration success, got $rc";
 else [[ $rc != 0 ]] || fail 'expected migration refusal/failure'; fi
 if grep -q private-do-not-print "$case_dir/output"; then fail 'secret leaked to output'; fi
 same "$case_dir/expected-state" "$case_dir/state/state.json"
 same "$case_dir/expected-config" "$case_dir/etc/config.json"
 same "$case_dir/expected-xray" "$case_dir/install/xray"
}

create_case success
run_case pass
same "$case_dir/package/x-ui" "$case_dir/install/x-ui"
grep -Fqx "ExecStart=$case_dir/install/x-ui -config $case_dir/etc/config.json" "$case_dir/etc/angelo-node.service" || fail 'unit did not switch executable'
[[ $(cat "$case_dir/service-status") == active ]] || fail 'migrated service stopped'
[[ -n $(find "$case_dir/backups" -mindepth 3 -maxdepth 3 -path '*/state/state.json' -print -quit) ]] || fail 'state backup missing'
echo 'PASS migration switches executable and preserves live data and original Xray'

create_case failed-health
TEST_MODE=failed-health
run_case fail
same "$case_dir/expected-unit" "$case_dir/etc/angelo-node.service"
[[ ! -e $case_dir/install/x-ui ]] || fail 'failed candidate left at new process path'
[[ $(cat "$case_dir/service-status") == active ]] || fail 'original service was not restored'
echo 'PASS failed candidate restores old process and preserves current data'

create_case partial-install
TEST_MODE=partial-install
run_case fail
same "$case_dir/expected-unit" "$case_dir/etc/angelo-node.service"
[[ ! -e $case_dir/install/x-ui ]] || fail 'partial executable remained after failed install'
[[ $(cat "$case_dir/service-status") == active ]] || fail 'service was not restored after failed install'
echo 'PASS partial executable write is removed and old service recovers'

create_case failed-unit-move
TEST_MODE=failed-unit-move
run_case fail
same "$case_dir/expected-unit" "$case_dir/etc/angelo-node.service"
[[ ! -e $case_dir/install/x-ui ]] || fail 'failed unit move left new executable'
[[ $(cat "$case_dir/service-status") == active ]] || fail 'service was not restored after unit move failure'
echo 'PASS failed unit switch restores old service'

create_case bad-checksum
printf '%064d  angelo-node-linux-amd64.tar.gz\n' 0 >"$case_dir/releases/SHA256SUMS"
run_case fail
if grep -Eq '^(stop|start) ' "$case_dir/service-log"; then fail 'bad asset stopped service'; fi
same "$case_dir/expected-unit" "$case_dir/etc/angelo-node.service"
echo 'PASS checksum mismatch refuses before service stop'

create_case existing-name
printf 'other executable\n' >"$case_dir/install/x-ui"
run_case fail
[[ ! -s $case_dir/network-log ]] || fail 'existing target was overwritten after network access'
same "$case_dir/expected-unit" "$case_dir/etc/angelo-node.service"
echo 'PASS existing x-ui refuses overwrite'
