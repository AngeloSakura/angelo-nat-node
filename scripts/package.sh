#!/usr/bin/env bash
set -euo pipefail
version=${VERSION:-v0.1.0}
mkdir -p dist
for target in amd64 arm64 386 armv7; do
 arch=$target
 arm=
 if [ "$target" = armv7 ];then arch=arm;arm=7;fi
 CGO_ENABLED=0 GOOS=linux GOARCH=$arch GOARM=$arm go build -trimpath -ldflags="-s -w -X github.com/AngeloSakura/angelo-nat-node/internal/node.Version=$version" -o "dist/angelo-node-linux-$target" ./cmd/angelo-node
 stage=$(mktemp -d)
 cp "dist/angelo-node-linux-$target" "$stage/angelo-node"
 cp scripts/update-node.sh scripts/angelo-node.service LICENSE "$stage/"
 chmod 755 "$stage/angelo-node" "$stage/update-node.sh"
 tar -czf "dist/angelo-node-linux-$target.tar.gz" -C "$stage" angelo-node update-node.sh angelo-node.service LICENSE
 rm -rf -- "$stage"
done
cp scripts/install.sh scripts/update-master.sh dist/
(cd dist;sha256sum *.tar.gz install.sh update-master.sh > SHA256SUMS)
