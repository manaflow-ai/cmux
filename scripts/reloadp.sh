#!/usr/bin/env bash
set -euo pipefail

xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Release -destination 'platform=macOS' build
pkill -x cmuxterm || true
sleep 0.2
APP_PATH="$(
  find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/cmuxterm.app" -print0 \
  | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
  | sort -nr \
  | head -n 1 \
  | cut -d' ' -f2-
)"
if [[ -z "${APP_PATH}" ]]; then
  echo "cmuxterm.app not found in DerivedData" >&2
  exit 1
fi
open "$APP_PATH"
osascript -e 'tell application "cmuxterm" to activate' || true
