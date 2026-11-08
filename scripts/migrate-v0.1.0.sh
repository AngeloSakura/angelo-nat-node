#!/bin/sh
# One-time executable-name migration. Never replace or restore persisted state.
set -eu
umask 077
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$(uname -s)" = Linux ] && [ "$(id -u)" = 0 ] || fail 'Root Linux required'
for tool in curl tar sha256sum systemctl install flock realpath mktemp cp mv awk date; do
 command -v "$tool" >/dev/null 2>&1 || fail "Missing $tool"
done
old=/usr/local/bin/angelo-node
new=/usr/local/bin/x-ui
config=/etc/angelo-node/config.json
unit=/etc/systemd/system/angelo-node.service
service=angelo-node.service
backup_root=/var/backups/angelo-node
[ -f "$old" ] && [ -x "$old" ] && [ ! -L "$old" ] || fail 'v0.1.0 executable is missing or is a symlink'
[ "$("$old" -version)" = v0.1.0 ] || fail 'Only v0.1.0 can use this migration'
[ ! -e "$new" ] && [ ! -L "$new" ] || fail 'x-ui executable already exists; refusing to overwrite it'
[ -f "$config" ] && [ ! -L "$config" ] || fail 'Configuration missing or symlinked'
[ -f "$unit" ] && [ ! -L "$unit" ] || fail 'Service unit missing or symlinked'
[ "$(systemctl show --property=FragmentPath --value "$service")" = "$unit" ] || fail 'Loaded service is not the expected unit'
case "$(systemctl show --property=ExecStart --value "$service")" in
 *"path=$old "*) ;;
 *) fail 'Loaded service does not run the v0.1.0 executable';;
esac
[ "$(awk '$0=="ExecStart=/usr/local/bin/angelo-node -config /etc/angelo-node/config.json" {n++} END {print n+0}' "$unit")" = 1 ] || fail 'Service unit has an unexpected ExecStart'
systemctl is-active --quiet "$service" || fail 'Existing node service must be active'
"$old" -config "$config" -health-check >/dev/null 2>&1 || fail 'Existing node is unhealthy; migrate after repair'
state_dir=$("$old" -config "$config" -state-dir-path)
case "$state_dir" in /*) ;; *) fail 'State path must be absolute';; esac
[ -d "$state_dir" ] && [ ! -L "$state_dir" ] && [ -f "$state_dir/state.json" ] && [ ! -L "$state_dir/state.json" ] || fail 'Persistent state missing or symlinked'
state_dir=$(realpath -e -- "$state_dir")
[ "$state_dir" != / ] || fail 'Refusing root state directory'
backup_root=$(realpath -m -- "$backup_root")
case "$backup_root/" in "$state_dir/"*) fail 'Backup must be outside state directory';; esac
exec 9>"$old.update.lock"
flock -n 9 || fail 'Another node update is running'
exec 8>"$new.update.lock"
flock -n 8 || fail 'Another x-ui update is running'
case "$(uname -m)" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; i?86) arch=386;; armv7l) arch=armv7;; *) fail 'Unsupported architecture';; esac
stage=$(mktemp -d "${TMPDIR:-/var/tmp}/angelo-name-migration.XXXXXX")
backup=
unit_pending=
stopped=0
unit_changed=0
installed=0
complete=0
recover() {
 code=$?
 trap - EXIT HUP INT TERM
 set +e
 if [ "$complete" != 1 ] && [ "$stopped" = 1 ]; then
  systemctl stop "$service" >/dev/null 2>&1
  if systemctl is-active --quiet "$service"; then
   printf '%s\n' 'CRITICAL: service did not stop; recovery refused.' >&2
  else
   can_restart=1
   if [ -n "$backup" ]; then
    cp -a -- "$state_dir" "$backup/state-after-failed-start" || true
   fi
   if [ "$unit_changed" = 1 ] && [ -n "$backup" ]; then
    if cp -p -- "$backup/angelo-node.service" "$unit" && systemctl daemon-reload; then
     :
    else
     printf '%s\n' 'CRITICAL: unit recovery failed; inspect private backup before restarting.' >&2
     can_restart=0
    fi
   fi
   if [ "$installed" = 1 ]; then rm -f -- "$new"; fi
   if [ "$can_restart" = 1 ] && "$old" -config "$config" -check >/dev/null 2>&1 && systemctl start "$service" && "$old" -config "$config" -health-check >/dev/null 2>&1; then
    printf '%s\n' 'Original v0.1.0 service restored; current users and counters retained.' >&2
   else
    systemctl stop "$service" >/dev/null 2>&1
    printf '%s\n' 'Recovery needs attention; service left stopped, state was not overwritten.' >&2
   fi
  fi
  code=1
 fi
 [ -z "$backup" ] || printf 'Private backup: %s\n' "$backup" >&2
 [ -z "$unit_pending" ] || rm -f -- "$unit_pending"
 case "$stage" in "${TMPDIR:-/var/tmp}/angelo-name-migration."*) rm -rf -- "$stage";; esac
 exit "$code"
}
trap recover EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
asset=angelo-node-linux-$arch.tar.gz
base=https://github.com/AngeloSakura/angelo-nat-node/releases/download/v0.1.1
curl -fL --retry 3 --connect-timeout 15 --max-filesize 33554432 "$base/$asset" -o "$stage/$asset"
curl -fL --retry 3 --connect-timeout 15 --max-filesize 1048576 "$base/SHA256SUMS" -o "$stage/SHA256SUMS"
(cd "$stage"; awk -v name="$asset" '$2==name || $2=="*"name {if(length($1)!=64 || $1~/[^0-9a-fA-F]/ || NF!=2) exit 1; print $1 "  " name; count++} END {if(count!=1) exit 1}' SHA256SUMS > selected; sha256sum -c selected)
tar -tzf "$stage/$asset" | awk '$0=="x-ui" {n++} END {if(n!=1) exit 1}' || fail 'Release archive must have exactly one x-ui executable'
tar -xOzf "$stage/$asset" x-ui >"$stage/x-ui"
[ -s "$stage/x-ui" ] || fail 'Empty x-ui executable'
chmod 755 "$stage/x-ui"
[ "$("$stage/x-ui" -version)" = v0.1.1 ] || fail 'Wrong release version'
"$stage/x-ui" -config "$config" -check >/dev/null || fail 'New executable cannot read existing state'
install -d -m 700 "$backup_root"
stopped=1
systemctl stop "$service"
systemctl is-active --quiet "$service" && fail 'Existing service did not stop'
backup=$(mktemp -d "$backup_root/name-migration-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
cp -p -- "$old" "$backup/angelo-node"
cp -p -- "$unit" "$backup/angelo-node.service"
cp -p -- "$config" "$backup/config.json"
cp -a -- "$state_dir" "$backup/state"
"$stage/x-ui" -config "$config" -check >/dev/null || fail 'New executable failed state check after checkpoint'
[ ! -e "$new" ] && [ ! -L "$new" ] || fail 'x-ui executable appeared during migration; refusing to overwrite it'
installed=1
install -m 755 "$stage/x-ui" "$new"
awk '$0=="ExecStart=/usr/local/bin/angelo-node -config /etc/angelo-node/config.json" {$0="ExecStart=/usr/local/bin/x-ui -config /etc/angelo-node/config.json"} {print}' "$unit" >"$stage/unit"
chmod --reference="$unit" "$stage/unit"
unit_pending=$(mktemp "${unit%/*}/.angelo-node.service.XXXXXX")
cp -p -- "$stage/unit" "$unit_pending"
unit_changed=1
mv -f -- "$unit_pending" "$unit"
unit_pending=
systemctl daemon-reload
case "$(systemctl show --property=ExecStart --value "$service")" in
 *"path=$new "*) ;;
 *) fail 'Loaded unit did not switch to x-ui';;
esac
systemctl start "$service"
deadline=$(( $(date +%s) + 30 ))
while :; do
 if systemctl is-active --quiet "$service" && "$new" -config "$config" -health-check >/dev/null 2>&1; then break; fi
 [ "$(date +%s)" -lt "$deadline" ] || fail 'Migrated node failed health check'
 sleep 1
done
pid=$(systemctl show --property=MainPID --value "$service")
case "$pid" in ''|*[!0-9]*) fail 'Cannot verify node process PID';; esac
[ "$pid" -gt 0 ] && [ "$(cat "/proc/$pid/comm")" = x-ui ] && [ "$(readlink -f "/proc/$pid/exe")" = "$new" ] || fail 'Running process is not the new x-ui executable'
complete=1
printf '%s\n' 'Migrated to v0.1.1 x-ui executable. Token, users, counters, config and original Xray remain unchanged.'
