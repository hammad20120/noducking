#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in
  release)
    APP=build/NoDucking.app
    COMPILER_FLAGS=(-O)
    ;;
  debug)
    APP=build/debug/NoDucking.app
    COMPILER_FLAGS=(-O -D DEBUG)
    ;;
  *)
    echo "usage: build.sh [release|debug]"
    exit 1
    ;;
esac
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -target arm64-apple-macos14.4 "${COMPILER_FLAGS[@]}" Sources/*.swift -o "$APP/Contents/MacOS/NoDucking" -framework AppKit -framework CoreAudio
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --options runtime --sign - "$APP"
echo "built $APP"
