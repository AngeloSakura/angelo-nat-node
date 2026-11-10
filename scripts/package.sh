#!/usr/bin/env bash
set -euo pipefail
version=${VERSION:-v0.1.6}
mkdir -p dist
for target in amd64 arm64 386 armv7; do
 arch=$target
 arm=
 if [ "$target" = armv7 ];then arch=arm;arm=7;fi
 CGO_ENABLED=0 GOOS=linux GOARCH=$arch GOARM=$arm go build -trimpath -ldflags="-s -w -X github.com/AngeloSakura/angelo-nat-node/internal/node.Version=$version" -o "dist/angelo-node-linux-$target" ./cmd/angelo-node
 stage=$(mktemp -d)
 cp "dist/angelo-node-linux-$target" "$stage/x-ui"
 cp scripts/update-node.sh scripts/angelo-node.service scripts/angelo-node.openrc LICENSE "$stage/"
 chmod 755 "$stage/x-ui" "$stage/update-node.sh" "$stage/angelo-node.openrc"
 tar -czf "dist/angelo-node-linux-$target.tar.gz" -C "$stage" x-ui update-node.sh angelo-node.service angelo-node.openrc LICENSE
 rm -rf -- "$stage"
done
cp scripts/install.sh scripts/update-node.sh scripts/update-master.sh scripts/migrate-v0.1.0.sh dist/
(cd dist;sha256sum *.tar.gz install.sh update-node.sh update-master.sh migrate-v0.1.0.sh > SHA256SUMS)
