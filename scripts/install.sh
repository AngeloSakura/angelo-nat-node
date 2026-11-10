#!/bin/sh
set -eu
umask 077
fail() { printf '%s\n' "ERROR: $*" >&2; exit 1; }
repo=AngeloSakura/angelo-nat-node
version=${1:-v0.1.7}
[ "$#" -le 1 ] || fail 'Usage: install.sh vX.Y.Z'
case "$version" in v[0-9]*.[0-9]*.[0-9]*) ;; *) fail 'Usage: install.sh vX.Y.Z';; esac
case "$version" in *[!a-zA-Z0-9._-]*) fail 'Invalid release tag';; esac
[ "$(uname -s)" = Linux ] || fail 'Linux required'
[ "$(id -u)" = 0 ] || fail 'Run as root'
install_missing_packages() {
 missing=0
 for tool in curl tar sha256sum install flock mktemp awk date unzip; do
  command -v "$tool" >/dev/null 2>&1 || missing=1
 done
 if [ "$missing" = 0 ]; then return 0; fi
 if command -v apk >/dev/null 2>&1; then
  apk add --no-cache curl tar coreutils util-linux unzip
 elif command -v apt-get >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar coreutils util-linux unzip
 else
  fail 'Missing required packages and no supported package manager was found'
 fi
 for tool in curl tar sha256sum install flock mktemp awk date unzip; do
  command -v "$tool" >/dev/null 2>&1 || fail "Missing: $tool"
 done
}
install_missing_packages
if ! command -v systemctl >/dev/null 2>&1 && ! command -v rc-service >/dev/null 2>&1 && command -v apk >/dev/null 2>&1; then
 apk add --no-cache openrc
fi
if command -v systemctl >/dev/null 2>&1; then
 service_backend=systemd
 service=angelo-node.service
 service_path=/etc/systemd/system/angelo-node.service
 service_member=angelo-node.service
 command -v systemctl >/dev/null 2>&1 || fail 'Missing: systemctl'
elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
 service_backend=openrc
 service=angelo-node
 service_path=/etc/init.d/angelo-node
 service_member=angelo-node.openrc
else
 fail 'Missing: systemctl or OpenRC (rc-service and rc-update)'
fi
config_dir=/etc/angelo-node
state_dir=/var/lib/angelo-node
library_dir=/usr/local/lib/angelo-node
binary=/usr/local/bin/x-ui
updater=/usr/local/bin/angelo-node-update
unit=$service_path
lock=/run/lock/angelo-node-install.lock
startup_timeout=30
prompt_tty() {
 default=$1
 label=$2
 answer=$default
 if (tty -s </dev/tty) >/dev/null 2>&1; then
  printf '%s [%s]: ' "$label" "$default" >/dev/tty
  IFS= read -r entered </dev/tty || entered=
  [ -n "$entered" ] && answer=$entered
 fi
 printf '%s' "$answer"
}
validate_port() {
 case "$1" in ''|*[!0-9]*) return 1;; esac
 [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}
normalize_base_path() {
 value=$1
 case "$value" in
  ''|*[[:space:]]*) return 1;;
  *) printf '%s' "$value";;
 esac
}
exec 9>"$lock"
flock -n 9 || fail 'Another node installation is running'
# Refuse complete and partial installations, including dangling symlinks.
# Missing config must never replace surviving user state or keys.
for path in "$config_dir" "$state_dir" "$library_dir" "$binary" "$updater" "$unit"; do
 [ ! -e "$path" ] && [ ! -L "$path" ] || fail 'Existing node files found. Use angelo-node-update for updates; configuration and users will not be overwritten.'
done
case "$(uname -m)" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; i?86) arch=386;; armv7l) arch=armv7;; *) fail 'Unsupported architecture';; esac
port=${ANGELO_PORT:-}
while :; do
 if [ -z "$port" ]; then port=$(prompt_tty 2053 'API 端口'); fi
 if validate_port "$port"; then break; fi
 printf '%s\n' '端口无效，请输入 1-65535。' >&2
 port=
done
listen=${ANGELO_LISTEN:-:$port}
base_path=${ANGELO_BASE_PATH:-}
while :; do
 if [ -z "$base_path" ]; then base_path=$(prompt_tty / '访问路径（例如 /panel）'); fi
 if normalize_base_path "$base_path" >/dev/null; then break; fi
 printf '%s\n' '访问路径无效，请重试（例如 /panel 或 sakura）。' >&2
 base_path=
done
stage=$(mktemp -d "${TMPDIR:-/var/tmp}/angelo-install.XXXXXX")
service_attempted=0
completed=0
cleanup() {
 code=$?
 trap - EXIT HUP INT TERM
 set +e
 if [ "$completed" != 1 ] && [ "$service_attempted" = 1 ]; then
  if [ "$service_backend" = systemd ]; then
   systemctl disable --now "$service" >/dev/null 2>&1
   printf '%s\n' 'Node startup failed. New configuration/state remain in place; inspect journalctl -u angelo-node. Existing x-ui and Xray were not changed.' >&2
  else
   rc-service "$service" stop >/dev/null 2>&1
   rc-update del "$service" default >/dev/null 2>&1
   printf '%s\n' 'Node startup failed. New configuration/state remain in place; inspect /var/log/angelo-node*. Existing x-ui and Xray were not changed.' >&2
  fi
 fi
 case "$stage" in "${TMPDIR:-/var/tmp}/angelo-install."*) rm -rf -- "$stage";; esac
 exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
asset=angelo-node-linux-$arch.tar.gz
base=https://github.com/$repo/releases/download/$version
curl -fL --retry 3 --connect-timeout 15 --max-filesize 33554432 "$base/$asset" -o "$stage/$asset"
curl -fL --retry 3 --connect-timeout 15 --max-filesize 1048576 "$base/SHA256SUMS" -o "$stage/SHA256SUMS"
(cd "$stage"; awk -v name="$asset" '$2==name || $2=="*"name {if(length($1)!=64 || $1~/[^0-9a-fA-F]/ || NF!=2) exit 1; print $1 "  " name; count++} END {if(count!=1) exit 1}' SHA256SUMS > selected; sha256sum -c selected)
# Stream only expected members; never unpack arbitrary paths or links.
tar -tzf "$stage/$asset" >"$stage/members"
for member in x-ui update-node.sh "$service_member"; do
 awk -v name="$member" '$0==name {count++} END {if(count!=1) exit 1}' "$stage/members" || fail "Archive must contain exactly one $member"
 tar -xOzf "$stage/$asset" "$member" >"$stage/$member"
 [ -s "$stage/$member" ] || fail "Release member is empty or not a regular file: $member"
done
chmod 755 "$stage/x-ui"
[ "$("$stage/x-ui" -version)" = "$version" ] || fail 'Release executable version does not match requested tag'
# Existing Xray is copied byte-for-byte. The old service is never stopped.
existing=${XRAY_BINARY:-}
if [ -z "$existing" ]; then
 for candidate in /usr/local/x-ui/bin/xray-linux-$arch /usr/local/bin/xray; do
  if [ -f "$candidate" ] && [ -x "$candidate" ]; then existing=$candidate; break; fi
 done
fi
if [ -n "$existing" ]; then
 [ -f "$existing" ] && [ -x "$existing" ] || fail 'XRAY_BINARY must be an existing executable file'
 install -m 755 "$existing" "$stage/xray"
else
 command -v unzip >/dev/null 2>&1 || fail 'Install unzip or specify XRAY_BINARY=/path/to/xray'
 case "$arch" in
 amd64) xasset=Xray-linux-64.zip; digest=e4bd9119f50ae7c41658b1abd0679ae06f98bd864a2907ff33f2f2cf7081b214;;
 arm64) xasset=Xray-linux-arm64-v8a.zip; digest=1811c8f1da0c3b6dc707ebaf1c8390e987ba39859a8f0a7aadd8526157f2ec8d;;
 386) xasset=Xray-linux-32.zip; digest=4064a12c7712f28f0a85082be3564c088f7861f2220ddb5e4de409c91837511d;;
 armv7) xasset=Xray-linux-arm32-v7a.zip; digest=2387f55239ee7799fd67d5382e79f589c1da07a97d993e86b058f2290b8e456b;;
 esac
 curl -fL --retry 3 --connect-timeout 15 --max-filesize 67108864 "https://github.com/XTLS/Xray-core/releases/download/v26.10.31/$xasset" -o "$stage/xray.zip"
 printf '%s  %s\n' "$digest" "$stage/xray.zip" | sha256sum -c -
unzip -l "$stage/xray.zip" >"$stage/xray-members"
xray_members=$(grep -E '[[:space:]]xray[[:space:]]*$' "$stage/xray-members" 2>/dev/null || true)
xray_count=$(printf '%s\n' "$xray_members" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
[ "$xray_count" = 1 ] || fail 'Xray archive must contain exactly one xray executable'
 unzip -p "$stage/xray.zip" xray >"$stage/xray"
 [ -s "$stage/xray" ] || fail 'Xray executable is empty'
 chmod 755 "$stage/xray"
fi
"$stage/xray" version >/dev/null || fail 'Xray executable cannot run on this machine'
# All artifacts are checked before creating installation files.
install -d -m 700 "$config_dir" "$state_dir" "$state_dir/backups"
install -d -m 755 "$library_dir" "${binary%/*}"
install -m 755 "$stage/x-ui" "$binary"
install -m 755 "$stage/update-node.sh" "$updater"
install -m 755 "$stage/xray" "$library_dir/xray"
"$binary" -config "$config_dir/config.json" -init -listen "$listen" -base-path "$base_path" -state-dir "$state_dir" -xray "$library_dir/xray"
if [ "$service_backend" = systemd ]; then
 install -m 644 "$stage/$service_member" "$unit"
 systemctl daemon-reload
else
 install -m 755 "$stage/$service_member" "$unit"
fi
service_attempted=1
if [ "$service_backend" = systemd ]; then
 systemctl enable --now "$service"
else
 rc-update add "$service" default
 rc-service "$service" start
fi
deadline=$(( $(date +%s) + startup_timeout ))
while :; do
 if { [ "$service_backend" = systemd ] && systemctl is-active --quiet "$service"; } || { [ "$service_backend" = openrc ] && rc-service "$service" status >/dev/null 2>&1; }; then
  if "$binary" -config "$config_dir/config.json" -health-check >/dev/null 2>&1; then break; fi
 fi
 [ "$(date +%s)" -lt "$deadline" ] || fail 'Authenticated API/Xray health check failed'
 sleep 1
done
completed=1
printf '%s\n' 'Installed. The x-ui management menu is opening; use its connection details to configure the master.'
if (tty -s </dev/tty) >/dev/null 2>&1; then
 exec "$binary"
fi
