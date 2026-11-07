#!/bin/sh
set -eu
umask 077
repo=AngeloSakura/angelo-nat-node
version=${1:-v0.1.0}
case "$version" in v[0-9]*.[0-9]*.[0-9]*) ;; *) echo 'Usage: install.sh vX.Y.Z' >&2; exit 1;; esac
case "$version" in *[!a-zA-Z0-9._-]*) exit 1;; esac
[ "$(id -u)" = 0 ] || { echo 'Run as root' >&2; exit 1; }
[ ! -e /etc/angelo-node/config.json ] || { echo 'Already installed. Use angelo-node-update; configuration will not be overwritten.' >&2; exit 1; }
for tool in curl tar sha256sum systemctl install; do command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 1; }; done
case "$(uname -m)" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; i?86) arch=386;; armv7l) arch=armv7;; *) echo 'Unsupported architecture' >&2;exit 1;; esac
stage=$(mktemp -d /var/tmp/angelo-install.XXXXXX)
trap 'rm -rf -- "$stage"' EXIT HUP INT TERM
asset=angelo-node-linux-$arch.tar.gz
base=https://github.com/$repo/releases/download/$version
curl -fL --retry 3 --connect-timeout 15 "$base/$asset" -o "$stage/$asset"
curl -fL --retry 3 --connect-timeout 15 "$base/SHA256SUMS" -o "$stage/SHA256SUMS"
(cd "$stage"; awk -v name="$asset" '$2==name {print; found=1} END {if(!found) exit 1}' SHA256SUMS > selected; sha256sum -c selected)
tar -xzf "$stage/$asset" -C "$stage"
install -d -m 700 /etc/angelo-node /var/lib/angelo-node /var/lib/angelo-node/backups
install -d -m 755 /usr/local/lib/angelo-node
install -m 755 "$stage/angelo-node" /usr/local/bin/angelo-node
install -m 755 "$stage/update-node.sh" /usr/local/bin/angelo-node-update
# Existing Xray is copied byte-for-byte; nothing in an existing installation is replaced.
existing=${XRAY_BINARY:-}
if [ -z "$existing" ]; then
 for candidate in /usr/local/x-ui/bin/xray-linux-$arch /usr/local/bin/xray; do if [ -x "$candidate" ]; then existing=$candidate;break;fi;done
fi
if [ -n "$existing" ]; then
 [ -x "$existing" ] || { echo 'XRAY_BINARY is not executable' >&2;exit 1; }
 install -m 755 "$existing" /usr/local/lib/angelo-node/xray
else
 command -v unzip >/dev/null || { echo 'Install unzip or specify XRAY_BINARY=/path/to/xray' >&2;exit 1; }
 case "$arch" in
 amd64) xasset=Xray-linux-64.zip; digest=e4bd9119f50ae7c41658b1abd0679ae06f98bd864a2907ff33f2f2cf7081b214;;
 arm64) xasset=Xray-linux-arm64-v8a.zip; digest=1811c8f1da0c3b6dc707ebaf1c8390e987ba39859a8f0a7aadd8526157f2ec8d;;
 386) xasset=Xray-linux-32.zip; digest=4064a12c7712f28f0a85082be3564c088f7861f2220ddb5e4de409c91837511d;;
 armv7) xasset=Xray-linux-arm32-v7a.zip; digest=2387f55239ee7799fd67d5382e79f589c1da07a97d993e86b058f2290b8e456b;;
 esac
 curl -fL --retry 3 --connect-timeout 15 "https://github.com/XTLS/Xray-core/releases/download/v26.10.31/$xasset" -o "$stage/xray.zip"
 printf '%s  %s\n' "$digest" "$stage/xray.zip" | sha256sum -c -
 unzip -p "$stage/xray.zip" xray > "$stage/xray"
 install -m 755 "$stage/xray" /usr/local/lib/angelo-node/xray
fi
/usr/local/bin/angelo-node -init -listen "${ANGELO_LISTEN:-:2053}"
install -m 644 "$stage/angelo-node.service" /etc/systemd/system/angelo-node.service
systemctl daemon-reload
systemctl enable --now angelo-node
sleep 2
systemctl is-active --quiet angelo-node || { echo 'Startup failed; inspect journalctl -u angelo-node. Existing x-ui remains untouched.' >&2;exit 1; }
echo 'Installed. Use angelo-node -show to display the token. Map this API port through NAT and pin the certificate in the master.'
