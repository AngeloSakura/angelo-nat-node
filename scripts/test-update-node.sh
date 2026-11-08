#!/usr/bin/env bash
# Linux filesystem/rollback tests. All network and service operations are mocked.
# No production configuration, services, executables, or database are accessed.
set -Eeuo pipefail
[[ $(uname -s) == Linux ]] || { echo 'Run this preservation suite on Linux' >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
updater=$repo/scripts/update-node.sh
root=$(mktemp -d "${TMPDIR:-/tmp}/angelo-updater-tests.XXXXXXXX")
trap 'rm -rf -- "$root"' EXIT
original_path=$PATH
fail() { printf 'FAIL: %s\n' "$*" >&2; [[ ! -f ${case_dir:-}/output ]] || cat "$case_dir/output" >&2; exit 1; }
assert_same() { cmp -s -- "$1" "$2" || fail "content differs: $1 / $2"; }

create_case() {
 case_dir=$root/$1
 mkdir -p -- "$case_dir/bin" "$case_dir/installation" "$case_dir/custom state" "$case_dir/configuration" "$case_dir/releases" "$case_dir/package" "$case_dir/tmp"
 export TEST_CASE=$case_dir TEST_MODE=success TEST_BINARY=$case_dir/installation/x-ui TEST_STATE_DIR=$case_dir/'custom state'
 export TMPDIR=$case_dir/tmp
 export PATH=$case_dir/bin:$original_path
 printf 'active\n' >"$case_dir/service-status"
 : >"$case_dir/service-log"
 printf '{"stateDir":"%s","token":"private-token-do-not-print","tlsCert":"tls.crt","tlsKey":"tls.key"}\n' "$TEST_STATE_DIR" >"$case_dir/configuration/config.json"
 printf 'certificate bytes\n' >"$case_dir/configuration/tls.crt"
 printf 'private key bytes\n' >"$case_dir/configuration/tls.key"
 printf 'unchanged official Xray bytes\n' >"$case_dir/installation/xray"
 printf '{"schema":1,"guid":"stable-guid","nextId":2,"inbounds":[{"id":1,"tag":"nat","clients":["alice"]}],"traffic":{"alice":{"up":123,"down":456}},"global":{"master":{"alice":{"up":369,"down":1368}}}}\n' >"$TEST_STATE_DIR/state.json"
 printf '{"schema":1,"guid":"stable-guid","nextId":2,"inbounds":[{"id":1,"tag":"nat","clients":["alice"]}],"traffic":{"alice":{"up":223,"down":556}},"global":{"master":{"alice":{"up":369,"down":1368}}}}\n' >"$case_dir/advanced-state.json"
 cp "$TEST_STATE_DIR/state.json" "$case_dir/original-state.json"
 cp -a "$case_dir/configuration" "$case_dir/original-configuration"
 cp "$case_dir/installation/xray" "$case_dir/original-xray"
 cat >"$case_dir/node-template" <<'NODE'
#!/bin/sh
set -eu
version=VERSION_MARKER
mode=
while [ "$#" -gt 0 ]; do
 case "$1" in
  -config) shift 2;;
  -version|-state-dir-path|-check|-health-check) mode=$1; shift;;
  *) exit 31;;
 esac
done
case "$mode" in
 -version) printf '%s\n' "$version";;
 -state-dir-path) printf '%s\n' "$TEST_STATE_DIR";;
 -check)
  [ -f "$TEST_STATE_DIR/state.json" ] || exit 32
  if [ "$version" = v0.1.1 ] && [ "$TEST_MODE" = reject-check ]; then exit 33; fi
  if [ "$version" = v0.0.9 ] && [ "$TEST_MODE" = incompatible-state ] && [ -f "$TEST_CASE/new-started" ]; then exit 34; fi
  ;;
 -health-check)
  printf '%s\n' "health:$version" >>"$TEST_CASE/health-log"
  if [ "$version" = v0.1.1 ]; then
   case "$TEST_MODE" in failed-health|advanced-state|incompatible-state) exit 35;; esac
  fi
  ;;
 *) exit 36;;
esac
NODE
 sed 's/VERSION_MARKER/v0.0.9/' "$case_dir/node-template" >"$TEST_BINARY"
 sed 's/VERSION_MARKER/v0.1.1/' "$case_dir/node-template" >"$case_dir/package/x-ui"
 chmod 755 "$TEST_BINARY" "$case_dir/package/x-ui"
 cp "$TEST_BINARY" "$case_dir/original-node"
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
 case "$1" in -o) out=$2; shift 2;; --retry|--connect-timeout|--max-filesize) shift 2;; https://*) url=$1;shift;; *) shift;; esac
done
case "$url" in
 https://github.com/AngeloSakura/angelo-nat-node/releases/download/v0.1.1/SHA256SUMS) cp "$TEST_CASE/releases/SHA256SUMS" "$out";;
 https://github.com/AngeloSakura/angelo-nat-node/releases/download/v0.1.1/angelo-node-linux-amd64.tar.gz) cp "$TEST_CASE/releases/angelo-node-linux-amd64.tar.gz" "$out";;
 *) exit 40;;
esac
MOCK
 cat >"$case_dir/bin/systemctl" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$TEST_CASE/service-log"
case "$1" in
 show)
  case "$*" in
   *'--property=LoadState'*) echo loaded;;
   *'--property=ExecStart'*) printf '{ path=%s ; argv[]=%s -config %s ; }\n' "$TEST_BINARY" "$TEST_BINARY" "$TEST_CASE/configuration/config.json";;
   *) exit 42;;
  esac;;
 is-active) [ "$(cat "$TEST_CASE/service-status")" = active ];;
 stop)
  [ "$TEST_MODE" != stop-fails ] || exit 41
  echo inactive >"$TEST_CASE/service-status"
  ;;
 start)
  version=$("$TEST_BINARY" -version)
  if [ "$version" = v0.1.1 ]; then
   : >"$TEST_CASE/new-started"
   case "$TEST_MODE" in advanced-state|incompatible-state) cp "$TEST_CASE/advanced-state.json" "$TEST_STATE_DIR/state.json";; esac
  fi
  echo active >"$TEST_CASE/service-status"
  ;;
 *) exit 42;;
esac
MOCK
 chmod 755 "$case_dir/bin/"*
 package_release
}
package_release() {
 tar -czf "$case_dir/releases/angelo-node-linux-amd64.tar.gz" -C "$case_dir/package" x-ui
 (cd "$case_dir/releases"; sha256sum angelo-node-linux-amd64.tar.gz >SHA256SUMS)
}
run_update() {
 local rc=0
 sh "$updater" v0.1.1 --config "$case_dir/configuration/config.json" --binary "$TEST_BINARY" --service test-node.service --backup-root "$case_dir/backups" --startup-timeout 1 >"$case_dir/output" 2>&1 || rc=$?
 if [[ $1 == success ]]; then [[ $rc == 0 ]] || fail "expected successful update; exit=$rc";
 else [[ $rc != 0 ]] || fail 'expected update failure'; fi
 if grep -q private-token-do-not-print "$case_dir/output"; then fail 'updater leaked config token'; fi
}
assert_immutable() {
 diff -r -- "$case_dir/original-configuration" "$case_dir/configuration" >/dev/null || fail 'configuration, token or TLS files changed'
 assert_same "$case_dir/original-xray" "$case_dir/installation/xray"
}
find_backup() {
 backup=$(find "$case_dir/backups" -mindepth 1 -maxdepth 1 -type d -name 'v0.1.1-*' -print)
 [[ -n $backup && -d $backup ]] || fail 'expected one private backup'
}

create_case success
run_update success
[[ $("$TEST_BINARY" -version) == v0.1.1 ]] || fail 'new executable was not installed'
assert_immutable
assert_same "$case_dir/original-state.json" "$TEST_STATE_DIR/state.json"
find_backup
assert_same "$case_dir/original-state.json" "$backup/state/state.json"
assert_same "$case_dir/original-node" "$backup/x-ui"
grep -q '^health:v0.1.1$' "$case_dir/health-log" || fail 'new executable health was not checked'
printf 'PASS successful update preserves custom state, token, certificate, counters and Xray\n'

create_case failed-health
TEST_MODE=failed-health
run_update failure
assert_same "$case_dir/original-node" "$TEST_BINARY"
assert_same "$case_dir/original-state.json" "$TEST_STATE_DIR/state.json"
assert_immutable
[[ $(cat "$case_dir/service-status") == active ]] || fail 'old version did not recover'
grep -q '^health:v0.0.9$' "$case_dir/health-log" || fail 'rollback health was not checked'
printf 'PASS failed API/Xray health restores executable and verifies old service\n'

create_case advanced-state
TEST_MODE=advanced-state
run_update failure
assert_same "$case_dir/original-node" "$TEST_BINARY"
assert_same "$case_dir/advanced-state.json" "$TEST_STATE_DIR/state.json"
assert_immutable
find_backup
assert_same "$case_dir/original-state.json" "$backup/state/state.json"
assert_same "$case_dir/advanced-state.json" "$backup/state-after-failed-start/state.json"
[[ $(cat "$case_dir/service-status") == active ]] || fail 'old executable could not resume current compatible state'
printf 'PASS rollback retains newer counters and both recovery snapshots\n'

create_case incompatible-state
TEST_MODE=incompatible-state
run_update failure
assert_same "$case_dir/original-node" "$TEST_BINARY"
assert_same "$case_dir/advanced-state.json" "$TEST_STATE_DIR/state.json"
assert_immutable
[[ $(cat "$case_dir/service-status") == inactive ]] || fail 'old executable started with incompatible state'
printf 'PASS incompatible state remains untouched with service stopped\n'

create_case missing-state
rm -- "$TEST_STATE_DIR/state.json"
run_update failure
[[ ! -e $TEST_STATE_DIR/state.json ]] || fail 'missing state was silently initialized'
[[ ! -s $case_dir/service-log ]] || fail 'service touched before missing-state refusal'
assert_same "$case_dir/original-node" "$TEST_BINARY"
assert_immutable
printf 'PASS missing state refuses initialization before stopping service\n'

create_case reject-check
TEST_MODE=reject-check
run_update failure
[[ ! -s $case_dir/service-log ]] || fail 'service touched despite failed preflight'
assert_same "$case_dir/original-node" "$TEST_BINARY"
assert_same "$case_dir/original-state.json" "$TEST_STATE_DIR/state.json"
printf 'PASS incompatible candidate fails before downtime\n'

create_case checksum
printf '%064d  angelo-node-linux-amd64.tar.gz\n' 0 >"$case_dir/releases/SHA256SUMS"
run_update failure
[[ ! -s $case_dir/service-log ]] || fail 'service touched despite checksum failure'
assert_same "$case_dir/original-node" "$TEST_BINARY"
printf 'PASS checksum mismatch leaves installation running and unchanged\n'

create_case duplicate-checksum
cat "$case_dir/releases/SHA256SUMS" >>"$case_dir/releases/duplicate"
cat "$case_dir/releases/duplicate" >>"$case_dir/releases/SHA256SUMS"
run_update failure
[[ ! -s $case_dir/service-log ]] || fail 'service touched despite duplicate checksum'
assert_same "$case_dir/original-node" "$TEST_BINARY"
printf 'PASS duplicate checksum records are rejected\n'

create_case stopped-service
printf 'inactive\n' >"$case_dir/service-status"
run_update success
[[ $(cat "$case_dir/service-status") == inactive ]] || fail 'previously stopped service was started'
if grep -q '^start ' "$case_dir/service-log"; then fail 'previously stopped service received start'; fi
assert_same "$case_dir/original-state.json" "$TEST_STATE_DIR/state.json"
assert_immutable
printf 'PASS intentionally stopped service remains stopped\n'

create_case stop-fails
TEST_MODE=stop-fails
run_update failure
assert_same "$case_dir/original-node" "$TEST_BINARY"
assert_same "$case_dir/original-state.json" "$TEST_STATE_DIR/state.json"
assert_immutable
printf 'PASS failed service stop prevents executable replacement\n'

printf 'All node update preservation and recovery tests passed.\n'
