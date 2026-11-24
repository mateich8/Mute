#!/bin/zsh
# Build Mute.app — run from this directory: ./build.sh
set -e
cd "$(dirname "$0")"

# Pin the macOS 26.5 SDK. The CLT 27 SDK declares SwiftUI's @State, @Binding and
# friends as macros, but Command Line Tools ships no SwiftUIMacros plugin — that
# one lives inside Xcode — so every @State in the app fails to compile against
# MacOSX27.sdk with "plugin for module 'SwiftUIMacros' not found".
# With Xcode installed (e.g. on CI) the default SDK works, since Xcode ships the plugin.
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
if [ ! -d "$SDK" ]; then
  if xcode-select -p 2>/dev/null | grep -q '\.app/'; then
    SDK=$(xcrun --sdk macosx --show-sdk-path)
  else
    echo "error: $SDK is missing. Install Xcode, or point SDK at another macOS 26 SDK." >&2
    exit 1
  fi
fi

swiftc -O -parse-as-library -sdk "$SDK" -target arm64-apple-macos26.0 src/*.swift -o Mute

mkdir -p "Mute.app/Contents/MacOS" "Mute.app/Contents/Resources"
cp Mute "Mute.app/Contents/MacOS/Mute"
cp Info.plist "Mute.app/Contents/Info.plist"
# AppIcon.icns is the DARK design (bundle default — shown when the app isn't
# running; user lives in dark mode). AppIcon-Light.icns swaps in at runtime.
[ -f AppIcon.icns ] && cp AppIcon.icns "Mute.app/Contents/Resources/AppIcon.icns"
[ -f AppIcon-Light.icns ] && cp AppIcon-Light.icns "Mute.app/Contents/Resources/AppIcon-Light.icns"
codesign --force --sign - "Mute.app" 2>/dev/null || true

echo "Built Mute.app — launch with: open Mute.app"
