#!/bin/zsh
# Build Mute.app — run from this directory: ./build.sh
set -e
cd "$(dirname "$0")"

swiftc -O -parse-as-library -target arm64-apple-macos26.0 src/*.swift -o Mute

mkdir -p "Mute.app/Contents/MacOS" "Mute.app/Contents/Resources"
cp Mute "Mute.app/Contents/MacOS/Mute"
cp Info.plist "Mute.app/Contents/Info.plist"
# AppIcon.icns is the DARK design (bundle default — shown when the app isn't
# running; user lives in dark mode). AppIcon-Light.icns swaps in at runtime.
[ -f AppIcon.icns ] && cp AppIcon.icns "Mute.app/Contents/Resources/AppIcon.icns"
[ -f AppIcon-Light.icns ] && cp AppIcon-Light.icns "Mute.app/Contents/Resources/AppIcon-Light.icns"
codesign --force --sign - "Mute.app" 2>/dev/null || true

echo "Built Mute.app — launch with: open Mute.app"
