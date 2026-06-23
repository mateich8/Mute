#!/bin/zsh
# Build GlassPlay.app — run from this directory: ./build.sh
set -e
cd "$(dirname "$0")"

swiftc -O -parse-as-library -target arm64-apple-macos26.0 src/*.swift -o GlassPlay

mkdir -p "GlassPlay.app/Contents/MacOS" "GlassPlay.app/Contents/Resources"
cp GlassPlay "GlassPlay.app/Contents/MacOS/GlassPlay"
cp Info.plist "GlassPlay.app/Contents/Info.plist"
# AppIcon.icns is the DARK design (bundle default — shown when the app isn't
# running; user lives in dark mode). AppIcon-Light.icns swaps in at runtime.
[ -f AppIcon.icns ] && cp AppIcon.icns "GlassPlay.app/Contents/Resources/AppIcon.icns"
[ -f AppIcon-Light.icns ] && cp AppIcon-Light.icns "GlassPlay.app/Contents/Resources/AppIcon-Light.icns"
codesign --force --sign - "GlassPlay.app" 2>/dev/null || true

echo "Built GlassPlay.app — launch with: open GlassPlay.app"
