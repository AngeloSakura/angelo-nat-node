#!/usr/bin/env bash
# Real filesystem fixtures; network, identity and systemd are mocked.
# A temporary copy rewrites only fixed installation paths and health timeout.
# This suite never installs into /etc or /usr and never touches host services.
set -Eeuo pipefail
[[ $(uname -s) == Linux ]] || { echo 'Run this suite on Linux' >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for tool in python3 tar sha256sum awk flock install unzip; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
root=$(mktemp -d "${TMPDIR:-/tmp}/angelo-install-tests.XXXXXXXX")
trap 'rm -rf -- "$root"' EXIT
original_path=$PATH
fail() { printf 'FAIL: %s\n' "$*" >&2; [[ ! -f ${case_dir:-}/output ]] || cat "$case_dir/output" >&2; exit 1; }
assert_same() { cmp -s -- "$1" "$2" || fail "content differs: $1 / $2"; }

create_case() {
 case_dir=$root/$1
 mkdir -p "$case_dir/bin" "$case_dir/package" "$case_dir/releases" "$case_dir/tmp" "$case_dir/destination/etc/systemd/system" "$case_dir/destination/run/lock" "$case_dir/existing-xui/bin" "$case_dir/existing-global"
 export TEST_CASE=$case_dir TEST_MODE=success TMPDIR=$case_dir/tmp
 export TEST_STATE_DIR=$case_dir/destination/var/lib/angelo-node
 export PATH=$case_dir/bin:$original_path
 unset XRAY_BINARY ANGELO_LISTEN || true
 : >"$case_dir/service-log"
 : >"$case_dir/network-log"
 printf 'inactive\n' >"$case_dir/service-status"
 printf 'old master user database and multiplier settings\n' >"$case_dir/existing-xui/x-ui.db"
 printf 'old master configuration and private token\n' >"$case_dir/existing-xui/config.json"
 cat >"$case_dir/existing-xui/bin/xray-linux-amd64" <<'XRAY'
#!/bin/sh
[ "$*" = version ] || exit 41
printf 'Xray 26.10.31 (official fixture)\n'
XRAY
 chmod 755 "$case_dir/existing-xui/bin/xray-linux-amd64"
 cp -a "$case_dir/existing-xui" "$case_dir/original-xui"
 cat >"$case_dir/package/x-ui" <<'NODE'
#!/bin/sh
set -eu
version=v0.1.6
mode= config= state= xray= listen=
while [ "$#" -gt 0 ]; do
 case "$1" in
  -version|-init|-health-check) mode=$1;shift;;
  -config) config=$2;shift 2;;
  -base-path) shift 2;;
  -state-dir) state=$2;shift 2;;
  -xray) xray=$2;shift 2;;
  -listen) listen=$2;shift 2;;
  *) exit 50;;
 esac
done
case "$mode" in
 -version) printf '%s\n' "$version";;
 -init)
  [ ! -e "$config" ] && [ ! -L "$config" ] || exit 51
  [ -x "$xray" ] || exit 52
  set -C
  printf '{"stateDir":"%s","xrayPath":"%s","listen":"%s","token":"private-secret-do-not-print"}\n' "$state" "$xray" "$listen" >"$config"
  printf 'private TLS key\n' >"${config%/*}/tls.key"
  printf 'public TLS certificate\n' >"${config%/*}/tls.crt"
  ;;
 -health-check)
  printf 'health\n' >>"$TEST_CASE/health-log"
  [ -f "$config" ] && [ -f "$TEST_STATE_DIR/state.json" ] || exit 53
  [ "$TEST_MODE" != failed-health ] || exit 54
  ;;
 *) exit 55;;
esac
NODE
 printf '#!/bin/sh\nprintf update\n' >"$case_dir/package/update-node.sh"
 cp "$repo/scripts/angelo-node.service" "$case_dir/package/angelo-node.service"
 chmod 755 "$case_dir/package/x-ui" "$case_dir/package/update-node.sh"
 cat >"$case_dir/bin/id" <<'MOCK'
#!/bin/sh
[ "$*" = -u ] || exit 1
echo 0
MOCK
 cat >"$case_dir/bin/uname" <<'MOCK'
#!/bin/sh
case "$*" in -s) echo Linux;; -m) echo x86_64;; *) exit 1;; esac
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
 https://github.com/AngeloSakura/angelo-nat-node/releases/download/v0.1.6/SHA256SUMS) cp "$TEST_CASE/releases/SHA256SUMS" "$out";;
 https://github.com/AngeloSakura/angelo-nat-node/releases/download/v0.1.6/angelo-node-linux-amd64.tar.gz) cp "$TEST_CASE/releases/angelo-node-linux-amd64.tar.gz" "$out";;
 https://github.com/XTLS/Xray-core/releases/download/v26.10.31/Xray-linux-64.zip) printf 'tampered upstream asset\n' >"$out";;
 *) exit 60;;
esac
MOCK
 cat >"$case_dir/bin/systemctl" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$TEST_CASE/service-log"
case "$*" in
 'daemon-reload') ;;
 'enable --now angelo-node.service')
  [ "$TEST_MODE" != start-fails ] || exit 61
  printf 'active\n' >"$TEST_CASE/service-status"
  printf '{"guid":"stable-guid","users":["alice"],"traffic":{"alice":123}}\n' >"$TEST_STATE_DIR/state.json"
  ;;
 'is-active --quiet angelo-node.service') [ "$(cat "$TEST_CASE/service-status")" = active ];;
 'disable --now angelo-node.service') printf 'inactive\n' >"$TEST_CASE/service-status";;
 *) exit 62;;
esac
MOCK
 chmod 755 "$case_dir/bin/"*
 python3 - "$repo/scripts/install.sh" "$case_dir/installer.sh" "$case_dir" <<'PY'
import pathlib, shlex, sys
source, output, case = sys.argv[1:]
text = pathlib.Path(source).read_text()
replacements = {
 'config_dir=/etc/angelo-node': 'config_dir=' + shlex.quote(case + '/destination/etc/angelo-node'),
 'state_dir=/var/lib/angelo-node': 'state_dir=' + shlex.quote(case + '/destination/var/lib/angelo-node'),
 'library_dir=/usr/local/lib/angelo-node': 'library_dir=' + shlex.quote(case + '/destination/usr/local/lib/angelo-node'),
 'binary=/usr/local/bin/x-ui': 'binary=' + shlex.quote(case + '/destination/usr/local/bin/x-ui'),
 'updater=/usr/local/bin/angelo-node-update': 'updater=' + shlex.quote(case + '/destination/usr/local/bin/angelo-node-update'),
 'service_path=/etc/systemd/system/angelo-node.service': 'service_path=' + shlex.quote(case + '/destination/etc/systemd/system/angelo-node.service'),
 'lock=/run/lock/angelo-node-install.lock': 'lock=' + shlex.quote(case + '/destination/run/lock/angelo-node-install.lock'),
 'for candidate in /usr/local/x-ui/bin/xray-linux-$arch /usr/local/bin/xray; do': 'for candidate in "$TEST_CASE/existing-xui/bin/xray-linux-$arch" "$TEST_CASE/existing-global/xray"; do',
 'startup_timeout=30': 'startup_timeout=1',
}
for before, after in replacements.items():
 assert text.count(before) == 1, before
 text = text.replace(before, after)
pathlib.Path(output).write_text(text)
PY
 package_release
}
package_release() {
 tar -czf "$case_dir/releases/angelo-node-linux-amd64.tar.gz" -C "$case_dir/package" x-ui update-node.sh angelo-node.service
 (cd "$case_dir/releases"; sha256sum angelo-node-linux-amd64.tar.gz >SHA256SUMS)
}
run_install() {
 local rc=0
 sh "$case_dir/installer.sh" v0.1.6 >"$case_dir/output" 2>&1 || rc=$?
 if [[ $1 == success ]]; then [[ $rc == 0 ]] || fail "expected success, got $rc";
 else [[ $rc != 0 ]] || fail 'expected refusal/failure'; fi
 if grep -q private-secret-do-not-print "$case_dir/output"; then fail 'installer leaked token'; fi
 diff -r -- "$case_dir/original-xui" "$case_dir/existing-xui" >/dev/null || fail 'old master or Xray changed'
}
assert_no_install() {
 [[ ! -e $case_dir/destination/etc/angelo-node && ! -e $case_dir/destination/var/lib/angelo-node && ! -e $case_dir/destination/usr/local/bin/x-ui ]] || fail 'preflight failure wrote installation files'
 [[ ! -s $case_dir/service-log ]] || fail 'preflight failure touched services'
}

create_case fresh
run_install success
assert_same "$case_dir/original-xui/bin/xray-linux-amd64" "$case_dir/destination/usr/local/lib/angelo-node/xray"
assert_same "$case_dir/package/x-ui" "$case_dir/destination/usr/local/bin/x-ui"
grep -q '^ExecStart=/usr/local/bin/x-ui ' "$case_dir/destination/etc/systemd/system/angelo-node.service" || fail 'installed unit does not run x-ui executable'
[[ -s $case_dir/health-log ]] || fail 'authenticated API/Xray health was not checked'
[[ $(cat "$case_dir/service-status") == active ]] || fail 'new service inactive'
cp -a "$case_dir/destination" "$case_dir/snapshot"
: >"$case_dir/network-log"
: >"$case_dir/service-log"
run_install failure
diff -r "$case_dir/snapshot" "$case_dir/destination" >/dev/null || fail 'rerun changed installed state/token/files'
[[ ! -s $case_dir/network-log && ! -s $case_dir/service-log ]] || fail 'rerun accessed network/services'
printf 'PASS fresh install and rerun preserve original master/Xray and node state\n'

create_case existing-config
mkdir -p "$case_dir/destination/etc/angelo-node"
printf 'existing private config\n' >"$case_dir/destination/etc/angelo-node/config.json"
cp -a "$case_dir/destination/etc/angelo-node" "$case_dir/saved-config"
run_install failure
diff -r "$case_dir/saved-config" "$case_dir/destination/etc/angelo-node" >/dev/null || fail 'old config changed'
[[ ! -s $case_dir/network-log && ! -s $case_dir/service-log ]] || fail 'existing config refusal touched network/services'
printf 'PASS existing config refuses overwrite before network or service access\n'

create_case orphan-state
mkdir -p "$TEST_STATE_DIR"
printf '{"users":["alice"],"traffic":123}\n' >"$TEST_STATE_DIR/state.json"
cp "$TEST_STATE_DIR/state.json" "$case_dir/saved-state"
run_install failure
assert_same "$case_dir/saved-state" "$TEST_STATE_DIR/state.json"
[[ ! -s $case_dir/network-log && ! -s $case_dir/service-log ]] || fail 'partial-state refusal touched network/services'
printf 'PASS missing config does not reinitialize surviving users\n'

create_case dangling-config
ln -s "$case_dir/missing" "$case_dir/destination/etc/angelo-node"
run_install failure
[[ -L $case_dir/destination/etc/angelo-node && ! -s $case_dir/network-log ]] || fail 'dangling config symlink was replaced'
printf 'PASS dangling installation symlink refuses replacement\n'

create_case checksum
printf '%064d  angelo-node-linux-amd64.tar.gz\n' 0 >"$case_dir/releases/SHA256SUMS"
run_install failure
assert_no_install
printf 'PASS release checksum mismatch fails before installation\n'

create_case duplicate-checksum
cp "$case_dir/releases/SHA256SUMS" "$case_dir/sum"
cat "$case_dir/sum" >>"$case_dir/releases/SHA256SUMS"
run_install failure
assert_no_install
printf 'PASS duplicate checksum record is rejected\n'

create_case wrong-version
sed -i 's/version=v0.1.6/version=v0.0.9/' "$case_dir/package/x-ui"
package_release
run_install failure
assert_no_install
printf 'PASS mismatched executable version is rejected\n'

for variant in traversal duplicate symlink missing; do
 create_case "archive-$variant"
 python3 - "$case_dir" "$variant" <<'PY'
import io, pathlib, sys, tarfile
case = pathlib.Path(sys.argv[1]); variant = sys.argv[2]
archive = case / 'releases/angelo-node-linux-amd64.tar.gz'
with tarfile.open(archive, 'w:gz') as tar:
 for name in ('x-ui', 'update-node.sh', 'angelo-node.service'):
  if name == 'x-ui' and variant == 'symlink':
   item=tarfile.TarInfo(name);item.type=tarfile.SYMTYPE;item.linkname=str(case/'outside');tar.addfile(item)
  elif not (name == 'angelo-node.service' and variant == 'missing'):
   tar.add(case/'package'/name, arcname=name)
 if variant == 'duplicate': tar.add(case/'package/x-ui', arcname='x-ui')
 if variant == 'traversal':
  for name in ('../escaped', str(case/'absolute-escaped')):
   value=b'UNEXPECTED EXTRACTION';item=tarfile.TarInfo(name);item.size=len(value);tar.addfile(item,io.BytesIO(value))
PY
 (cd "$case_dir/releases"; sha256sum angelo-node-linux-amd64.tar.gz >SHA256SUMS)
 if [[ $variant == traversal ]]; then
  run_install success
  [[ ! -e $case_dir/absolute-escaped ]] || fail 'absolute archive path extracted'
  [[ -z $(find "$case_dir/tmp" -name escaped -print -quit) ]] || fail 'parent archive path extracted'
 else run_install failure;assert_no_install;fi
 printf 'PASS archive member safety: %s\n' "$variant"
done

create_case bad-existing-xray
export XRAY_BINARY=$case_dir/not-an-xray
printf '#!/bin/sh\nexit 1\n' >"$XRAY_BINARY"
chmod 755 "$XRAY_BINARY"
run_install failure
assert_no_install
printf 'PASS unusable supplied Xray fails before installation\n'

create_case fixed-xray-checksum
rm "$case_dir/existing-xui/bin/xray-linux-amd64" "$case_dir/original-xui/bin/xray-linux-amd64"
run_install failure
assert_no_install
grep -q '/XTLS/Xray-core/releases/download/v26.10.31/Xray-linux-64.zip$' "$case_dir/network-log" || fail 'official Xray URL was not pinned'
printf 'PASS downloaded Xray uses fixed release and rejects tampered bytes\n'

for mode in failed-health start-fails; do
 create_case "$mode"
 TEST_MODE=$mode
 run_install failure
 [[ $(cat "$case_dir/service-status") == inactive ]] || fail 'failed service left running'
 [[ -s $case_dir/destination/etc/angelo-node/config.json ]] || fail 'failed start erased generated config'
 grep -q '^disable --now angelo-node.service$' "$case_dir/service-log" || fail 'failed start not disabled'
 printf 'PASS failed startup retains recovery files and disables new service: %s\n' "$mode"
done

printf 'All installer preservation and archive-safety tests passed.\n'
