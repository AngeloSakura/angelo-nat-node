#!/bin/sh
set -eu
umask 077
version=${1:-}
case "$version" in v[0-9]*.[0-9]*.[0-9]*) ;; *) echo 'Usage: angelo-node-update vX.Y.Z' >&2;exit 1;; esac
case "$version" in *[!a-zA-Z0-9._-]*) exit 1;; esac
[ "$(id -u)" = 0 ] || { echo 'Run as root' >&2;exit 1; }
for tool in curl tar sha256sum systemctl install flock;do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2;exit 1; };done
exec 9>/run/angelo-node-update.lock
flock -n 9 || { echo 'Another update is running' >&2;exit 1; }
[ -f /etc/angelo-node/config.json ] || { echo 'Node not installed' >&2;exit 1; }
case "$(uname -m)" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; i?86) arch=386;; armv7l) arch=armv7;; *) exit 1;; esac
stage=$(mktemp -d /var/tmp/angelo-update.XXXXXX)
backup=/var/lib/angelo-node/backups/$(date -u +%Y%m%dT%H%M%SZ)-$$
stopped=0
recover(){
 code=$?
 trap - EXIT HUP INT TERM
 if [ "$code" != 0 ] && [ "$stopped" = 1 ];then
  systemctl stop angelo-node || true
  if [ -f "$backup/angelo-node" ];then install -m 755 "$backup/angelo-node" /usr/local/bin/angelo-node;fi
  if /usr/local/bin/angelo-node -check >/dev/null 2>&1;then systemctl start angelo-node || true;fi
  echo "Update failed. Original executable restored; user data was not overwritten. Backup: $backup" >&2
 fi
 rm -rf -- "$stage"
 exit "$code"
}
trap recover EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
asset=angelo-node-linux-$arch.tar.gz
base=https://github.com/AngeloSakura/angelo-nat-node/releases/download/$version
curl -fL --retry 3 --connect-timeout 15 "$base/$asset" -o "$stage/$asset"
curl -fL --retry 3 --connect-timeout 15 "$base/SHA256SUMS" -o "$stage/SHA256SUMS"
(cd "$stage";awk -v name="$asset" '$2==name{print;found=1}END{if(!found)exit 1}' SHA256SUMS > selected;sha256sum -c selected)
tar -xzf "$stage/$asset" -C "$stage"
"$stage/angelo-node" -version
systemctl stop angelo-node
stopped=1
install -d -m 700 "$backup"
cp -p /usr/local/bin/angelo-node "$backup/angelo-node"
cp -a /etc/angelo-node "$backup/config"
cp -p /var/lib/angelo-node/state.json "$backup/state.json"
"$stage/angelo-node" -check >/dev/null
install -m 755 "$stage/angelo-node" /usr/local/bin/angelo-node.new
mv /usr/local/bin/angelo-node.new /usr/local/bin/angelo-node
systemctl start angelo-node
sleep 3
systemctl is-active --quiet angelo-node
stopped=0
echo "Node updated to $version. Users, token, counters, certificate and original Xray are preserved. Backup: $backup"
