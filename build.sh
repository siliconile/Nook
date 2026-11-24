#!/bin/zsh
# Builds Nook.app into ./build.
#
#   ./build.sh                     release build for this Mac's architecture
#   ./build.sh debug               debug build
#   ./build.sh release --universal Apple silicon + Intel (used for GitHub releases)
#
# Environment:
#   NOOK_VERSION   marketing version written into Info.plist (e.g. 0.2.0)
#   NOOK_BUILD     build number written into Info.plist (e.g. 42)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
ARCH_FLAGS=()
if [[ "${2:-}" == "--universal" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)/Nook"

APP="build/Nook.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nook"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${NOOK_VERSION:-}" ]]; then
  plutil -replace CFBundleShortVersionString -string "$NOOK_VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${NOOK_BUILD:-}" ]]; then
  plutil -replace CFBundleVersion -string "$NOOK_BUILD" "$APP/Contents/Info.plist"
fi

# Now Playing bridge, loaded by /usr/bin/perl (see Helper/NookMediaBridge.m)
clang -dynamiclib -fobjc-arc -O2 -framework Foundation -arch arm64 -arch x86_64 \
  -o "$APP/Contents/Resources/NookMediaBridge.dylib" Helper/NookMediaBridge.m
codesign --force --sign - "$APP/Contents/Resources/NookMediaBridge.dylib"

# Fixed designated requirement: macOS privacy permissions (Accessibility for the HUD,
# Automation, Reminders) are keyed to it, so they survive rebuilds and updates. Without
# it an ad-hoc signature's requirement is its cdhash, which changes on every build.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' Resources/Info.plist)"
codesign --force --sign - --entitlements Resources/Nook.entitlements \
  -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Nook"))"
