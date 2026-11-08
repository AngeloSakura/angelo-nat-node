#!/bin/sh
set -eu
umask 077
fail() { printf '%s\n' "ERROR: $*" >&2; exit 1; }
repo=AngeloSakura/angelo-nat-node
version=${1:-v0.1.1}
[ "$#" -le 1 ] || fail 'Usage: install.sh vX.Y.Z'
case "$version" in v[0-9]*.[0-9]*.[0-9]*) ;; *) fail 'Usage: install.sh vX.Y.Z';; esac
case "$version" in *[!a-zA-Z0-9._-]*) fail 'Invalid release tag';; esac
[ "$(uname -s)" = Linux ] || fail 'Linux/systemd required'
[ "$(id -u)" = 0 ] || fail 'Run as root'
for tool in curl tar sha256sum systemctl install flock mktemp awk date; do
 command -v "$tool" >/dev/null 2>&1 || fail "Missing: $tool"
done
config_dir=/etc/angelo-node
state_dir=/var/lib/angelo-node
library_dir=/usr/local/lib/angelo-node
binary=/usr/local/bin/x-ui
updater=/usr/local/bin/angelo-node-update
unit=/etc/systemd/system/angelo-node.service
lock=/run/lock/angelo-node-install.lock
service=angelo-node.service
startup_timeout=30
exec 9>"$lock"
flock -n 9 || fail 'Another node installation is running'
# Refuse complete and partial installations, including dangling symlinks.
# Missing config must never replace surviving user state or keys.
for path in "$config_dir" "$state_dir" "$library_dir" "$binary" "$updater" "$unit"; do
 [ ! -e "$path" ] && [ ! -L "$path" ] || fail 'Existing node files found. Use angelo-node-update for updates; configuration and users will not be overwritten.'
done
case "$(uname -m)" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; i?86) arch=386;; armv7l) arch=armv7;; *) fail 'Unsupported architecture';; esac
stage=$(mktemp -d "${TMPDIR:-/var/tmp}/angelo-install.XXXXXX")
service_attempted=0
completed=0
cleanup() {
 code=$?
 trap - EXIT HUP INT TERM
 set +e
 if [ "$completed" != 1 ] && [ "$service_attempted" = 1 ]; then
  systemctl disable --now "$service" >/dev/null 2>&1
  printf '%s\n' 'Node startup failed. New configuration/state remain in place; inspect journalctl -u angelo-node. Existing x-ui and Xray were not changed.' >&2
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
for member in x-ui update-node.sh angelo-node.service; do
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
 unzip -Z1 "$stage/xray.zip" >"$stage/xray-members"
 awk '$0=="xray" {count++} END {if(count!=1) exit 1}' "$stage/xray-members" || fail 'Xray archive must contain exactly one xray executable'
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
"$binary" -config "$config_dir/config.json" -init -listen "${ANGELO_LISTEN:-:2053}" -state-dir "$state_dir" -xray "$library_dir/xray"
install -m 644 "$stage/angelo-node.service" "$unit"
systemctl daemon-reload
service_attempted=1
systemctl enable --now "$service"
deadline=$(( $(date +%s) + startup_timeout ))
while :; do
 if systemctl is-active --quiet "$service" && "$binary" -config "$config_dir/config.json" -health-check >/dev/null 2>&1; then break; fi
 [ "$(date +%s)" -lt "$deadline" ] || fail 'Authenticated API/Xray health check failed'
 sleep 1
done
completed=1
printf '%s\n' 'Installed. Use /usr/local/bin/x-ui -show to display the token. Map this API port through NAT and pin the certificate in the master.'
