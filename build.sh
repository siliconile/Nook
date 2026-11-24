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
# Now Playing bridge, loaded by /usr/bin/perl (see Helper/NookMediaBridge.m)
clang -dynamiclib -fobjc-arc -O2 -framework Foundation -arch arm64 -arch x86_64 \
  -o "$APP/Contents/Resources/NookMediaBridge.dylib" Helper/NookMediaBridge.m
codesign --force --sign - "$APP/Contents/Resources/NookMediaBridge.dylib"
codesign --force --sign - --entitlements Resources/Nook.entitlements "$APP"
echo "Built $APP"
