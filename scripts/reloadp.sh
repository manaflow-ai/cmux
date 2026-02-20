#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="${CMUX_XCODE_PROJECT:-cmux.xcodeproj}"
if [[ ! -d "$PROJECT" ]]; then
  DISCOVERED_PROJECT="$(find . -maxdepth 1 -type d -name '*.xcodeproj' | sort | head -n 1 | sed 's#^\\./##')"
  if [[ -n "$DISCOVERED_PROJECT" ]]; then
    PROJECT="$DISCOVERED_PROJECT"
  else
    echo "ERROR: Xcode project not found in repo root." >&2
    exit 1
  fi
fi

xcodebuild -project "$PROJECT" -scheme cmux -configuration Release -destination 'platform=macOS' build
pkill -x cmux || true
sleep 0.2
APP_PATH="$(
  find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/cmux.app" -print0 \
  | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
  | sort -nr \
  | head -n 1 \
  | cut -d' ' -f2-
)"
if [[ -z "${APP_PATH}" ]]; then
  echo "cmux.app not found in DerivedData" >&2
  exit 1
fi
# Dev shells (including CI/Codex) often force-disable paging by exporting these.
# Don't leak that into cmux, otherwise `git diff` won't page even with PAGER=less.
env -u GIT_PAGER -u GH_PAGER open "$APP_PATH"
osascript -e 'tell application "cmux" to activate' || true
