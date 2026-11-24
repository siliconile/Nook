#!/bin/zsh
# Packages build/Nook.app for a GitHub release: dist/Nook-<version>.zip + .sha256
# Usage: scripts/package.sh 0.2.0   (run ./build.sh release --universal first)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/package.sh <version>}"
APP="build/Nook.app"
[[ -d "$APP" ]] || { echo "Missing $APP — run ./build.sh release --universal first" >&2; exit 1; }

mkdir -p dist
ZIP="dist/Nook-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
# ditto keeps the bundle's signature, symlinks and extended attributes intact.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "Packaged $ZIP"
cat "$ZIP.sha256"
