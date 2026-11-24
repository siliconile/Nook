#!/bin/zsh
# Builds Nook.app into ./build. Usage: ./build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Nook"
APP="build/Nook.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nook"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --entitlements Resources/Nook.entitlements "$APP"
echo "Built $APP"
