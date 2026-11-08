#!/bin/sh
# Replace only the node executable. Never restore older user/config/traffic data.
set -eu
umask 077
usage() {
 cat <<'USAGE'
Usage: angelo-node-update vX.Y.Z [options]
  --config PATH          Existing config (default: /etc/angelo-node/config.json)
  --binary PATH          Existing node executable (default: /usr/local/bin/x-ui)
  --service NAME         Existing systemd service (default: angelo-node.service)
  --backup-root PATH     Private backups (default: /var/backups/angelo-node)
  --startup-timeout N    Health deadline in seconds, 1-300 (default: 30)
Use matching --config, --binary and --service when the installation is customized.
USAGE
}
fail() { printf '%s\n' "ERROR: $*" >&2; exit 1; }
version=${1:-}
case "$version" in --help|-h) usage;exit 0;; v[0-9]*.[0-9]*.[0-9]*) shift;; *) usage >&2;exit 1;; esac
case "$version" in *[!a-zA-Z0-9._-]*) fail 'Invalid release tag';; esac
config=/etc/angelo-node/config.json
binary=/usr/local/bin/x-ui
service=angelo-node.service
backup_root=/var/backups/angelo-node
startup_timeout=30
while [ "$#" -gt 0 ]; do
 [ "$#" -ge 2 ] || fail "Missing value for $1"
 case "$1" in
  --config) config=$2;;
  --binary) binary=$2;;
  --service) service=$2;;
  --backup-root) backup_root=$2;;
  --startup-timeout) startup_timeout=$2;;
  *) fail "Unknown option: $1";;
 esac
 shift 2
done
case "$service" in ''|*[!a-zA-Z0-9_.@-]*|-*) fail 'Invalid service name';; esac
case "$startup_timeout" in ''|*[!0-9]*) fail 'Invalid startup timeout';; esac
[ "${#startup_timeout}" -le 3 ] && [ "$startup_timeout" -ge 1 ] && [ "$startup_timeout" -le 300 ] || fail 'Startup timeout must be 1-300 seconds'
[ "$(uname -s)" = Linux ] || fail 'Linux/systemd required'
[ "$(id -u)" = 0 ] || fail 'Run as root'
for tool in curl tar sha256sum systemctl install flock realpath mktemp cp mv awk date; do
 command -v "$tool" >/dev/null 2>&1 || fail "Missing $tool"
done
startup_timeout=$(awk -v value="$startup_timeout" 'BEGIN {print value + 0}')
for path in "$config" "$binary" "$backup_root"; do
 case "$path" in /*) ;; *) fail 'Config, executable and backup paths must be absolute';; esac
done
[ -f "$config" ] && [ ! -L "$config" ] || fail 'Config must be an existing regular file, not a symlink'
[ -f "$binary" ] && [ -x "$binary" ] && [ ! -L "$binary" ] || fail 'Executable must be an existing regular executable, not a symlink'
config=$(realpath -e -- "$config")
binary=$(realpath -e -- "$binary")
[ "${binary##*/}" = x-ui ] || fail 'This release requires an x-ui executable. Migrate v0.1.0 first.'
backup_root=$(realpath -m -- "$backup_root")
[ "$backup_root" != / ] || fail 'Refusing backups at filesystem root'
install -d -m 700 "$backup_root"
# Tie the lock to the canonical executable, even if two callers choose different
# backup roots. Keep the lock file inode stable across runs.
exec 9>"$binary.update.lock"
flock -n 9 || fail 'Another node update is running'
case "$(uname -m)" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; i?86) arch=386;; armv7l) arch=armv7;; *) fail 'Unsupported architecture';; esac
stage=$(mktemp -d "${TMPDIR:-/var/tmp}/angelo-update.XXXXXX")
backup= pending= state_dir=
was_active=0
stopped=0
replaced=0
completed=0
atomic_binary() {
 pending=$(mktemp "${binary%/*}/.angelo-node.update.XXXXXX") || return 1
 install -m 755 "$1" "$pending" || return 1
 mv -f -- "$pending" "$binary" || return 1
 pending=
}
wait_healthy() {
 deadline=$(( $(date +%s) + startup_timeout ))
 while :; do
  if systemctl is-active --quiet "$service" && "$binary" -config "$config" -health-check >/dev/null 2>&1; then return 0; fi
  [ "$(date +%s)" -lt "$deadline" ] || return 1
  sleep 1
 done
}
recover() {
 code=$?
 trap - EXIT HUP INT TERM
 set +e
 if [ "$completed" != 1 ] && [ "$replaced" = 1 ]; then
  systemctl stop "$service" >/dev/null 2>&1
  if systemctl is-active --quiet "$service"; then
   printf '%s\n' 'CRITICAL: service did not stop; executable rollback refused. Inspect private backup.' >&2
  elif ! atomic_binary "$backup/x-ui"; then
   printf '%s\n' 'CRITICAL: executable rollback failed. Service left stopped; recover from private backup.' >&2
  else
   # Preserve evidence from a failed start, and never overwrite newer counters.
   cp -a -- "$state_dir" "$backup/state-after-failed-start" || printf '%s\n' 'Could not copy failed-start state; original data remains in place.' >&2
   if "$binary" -config "$config" -check >/dev/null 2>&1; then
    if [ "$was_active" = 1 ]; then
     if systemctl start "$service" && wait_healthy; then
      printf '%s\n' 'Previous executable restored and healthy; current user and traffic data retained.' >&2
     else
      systemctl stop "$service" >/dev/null 2>&1
      printf '%s\n' 'Previous executable restored, but health check failed. Service left stopped.' >&2
     fi
    fi
   else
    printf '%s\n' 'Previous executable restored. Current state is not readable by it; service left stopped for recovery. No user data was overwritten.' >&2
   fi
  fi
  code=1
 elif [ "$completed" != 1 ] && [ "$stopped" = 1 ] && [ "$was_active" = 1 ]; then
  if ! systemctl start "$service" || ! wait_healthy; then
   systemctl stop "$service" >/dev/null 2>&1
   printf '%s\n' 'Original executable unchanged, but restart health check failed. Service left stopped.' >&2
  fi
  code=1
 fi
 [ -z "$backup" ] || printf 'Private recovery backup: %s\n' "$backup" >&2
 [ -z "$pending" ] || rm -f -- "$pending"
 case "$stage" in "${TMPDIR:-/var/tmp}/angelo-update."*) rm -rf -- "$stage";; esac
 exit "$code"
}
trap recover EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
asset=angelo-node-linux-$arch.tar.gz
base=https://github.com/AngeloSakura/angelo-nat-node/releases/download/$version
curl -fL --retry 3 --connect-timeout 15 --max-filesize 33554432 "$base/$asset" -o "$stage/$asset"
curl -fL --retry 3 --connect-timeout 15 --max-filesize 1048576 "$base/SHA256SUMS" -o "$stage/SHA256SUMS"
(cd "$stage"; awk -v name="$asset" '$2==name || $2=="*"name {if(length($1)!=64 || $1~/[^0-9a-fA-F]/ || NF!=2) exit 1; print $1 "  " name; count++} END {if(count!=1) exit 1}' SHA256SUMS > selected; sha256sum -c selected)
# Stream only the executable into an already-created regular file. Archive paths
# and symlinks are never extracted into the installation or the staging tree.
tar -tzf "$stage/$asset" | awk '$0=="x-ui" {count++} END {if(count!=1) exit 1}' || fail 'Archive must contain exactly one node executable'
tar -xOzf "$stage/$asset" x-ui >"$stage/x-ui"
[ -s "$stage/x-ui" ] || fail 'Release executable is empty or missing'
chmod 755 "$stage/x-ui"
[ "$("$stage/x-ui" -version)" = "$version" ] || fail 'Release executable version does not match requested tag'
state_dir=$("$stage/x-ui" -config "$config" -state-dir-path) || fail 'Cannot resolve configured state directory'
case "$state_dir" in /*) ;; *) fail 'State directory must be absolute';; esac
[ -d "$state_dir" ] && [ ! -L "$state_dir" ] || fail 'State directory must exist and must not be a symlink'
state_dir=$(realpath -e -- "$state_dir")
[ "$state_dir" != / ] || fail 'Refusing filesystem root as state directory'
[ -f "$state_dir/state.json" ] && [ ! -L "$state_dir/state.json" ] || fail 'Existing state.json required; refusing to initialize missing state'
case "$backup_root/" in "$state_dir/"*) fail 'Backup root must be outside the state directory';; esac
case "$binary" in "$state_dir/"*) fail 'Executable must be outside the state directory';; esac
"$stage/x-ui" -config "$config" -check >/dev/null || fail 'New executable cannot read existing configuration/state'
load_state=$(systemctl show --property=LoadState --value "$service")
[ "$load_state" = loaded ] || fail 'Configured systemd service is not loaded'
unit_exec=$(systemctl show --property=ExecStart --value "$service")
case "$unit_exec" in *"path=$binary "*) ;; *) fail 'Loaded service does not execute the selected x-ui binary';; esac
if systemctl is-active --quiet "$service"; then was_active=1; fi
if [ "$was_active" = 1 ]; then
 # Set before stopping so an interrupted stop still attempts safe recovery.
 stopped=1
 systemctl stop "$service"
fi
if systemctl is-active --quiet "$service"; then fail 'Service is still active; refusing backup and replacement'; fi
backup=$(mktemp -d "$backup_root/$version-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
cp -p -- "$binary" "$backup/x-ui"
cp -p -- "$config" "$backup/config.json"
cp -a -- "$state_dir" "$backup/state"
printf 'version=%s\nservice=%s\nconfig=%s\nstate_dir=%s\nbinary=%s\n' "$version" "$service" "$config" "$state_dir" "$binary" >"$backup/paths.txt"
# Recheck after the service's final checkpoint before replacing anything.
"$stage/x-ui" -config "$config" -check >/dev/null
replaced=1
atomic_binary "$stage/x-ui"
if [ "$was_active" = 1 ]; then
 systemctl start "$service"
 wait_healthy || fail 'New node failed authenticated API/Xray health check'
else
 printf '%s\n' 'Service was stopped before the update and remains stopped.'
fi
completed=1
printf 'Node updated to %s. Configuration, users, token, certificates, counters and Xray were not replaced.\n' "$version"
