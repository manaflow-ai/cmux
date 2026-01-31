#!/usr/bin/env bash
set -euo pipefail

xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' build
pkill -x "cmuxterm DEV" || true
sleep 0.2
APP_PATH="$(
  find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/cmuxterm DEV.app" -print0 \
  | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
  | sort -nr \
  | head -n 1 \
  | cut -d' ' -f2-
)"
if [[ -z "${APP_PATH}" ]]; then
  echo "cmuxterm DEV.app not found in DerivedData" >&2
  exit 1
fi
open "$APP_PATH"
osascript -e 'tell application "cmuxterm DEV" to activate' || true
