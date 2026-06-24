#!/bin/zsh
# Capture Mute screenshots for the README and drop them in docs/.
#
# Usage:
#   ./tools/capture-screenshots.sh          # capture the frontmost window
#   ./tools/capture-screenshots.sh --screen # capture the whole screen
#   ./tools/capture-screenshots.sh --open   # launch Mute first if needed
#
# Tips:
#  - Put Mute in the state you want to show (Now Playing, mini player,
#    library grid, …) before running this.
#  - Run it repeatedly; each shot gets a timestamp so nothing is overwritten.
set -e
cd "$(dirname "$0")/.."
mkdir -p docs

launch=false
mode="window"
for arg in "$@"; do
  case "$arg" in
    --open)   launch=true ;;
    --screen) mode="screen" ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

if $launch; then
  open -a Mute.app 2>/dev/null || { echo "Mute.app not found — run ./build.sh first." >&2; exit 1; }
  echo "Launched Mute — set up your shot and press Enter to capture."
  read -r ?"Press Enter when ready… "
fi

ts=$(date +%Y%m%d-%H%M%S)
out="docs/screenshot-$ts.png"

if [[ "$mode" == "screen" ]]; then
  screencapture "$out"
else
  # -o disables the shadow, -w grabs the window under the cursor.
  screencapture -o -w "$out"
fi

echo "Saved $out"
