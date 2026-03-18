#!/usr/bin/env bash
set -euo pipefail

xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Release -destination 'platform=macOS' build
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

echo "Release app:"
echo "  ${APP_PATH}"

# Dev shells (including CI/Codex) often force-disable paging by exporting these.
# Don't leak that into cmux, otherwise `git diff` won't page even with PAGER=less.
env -u GIT_PAGER -u GH_PAGER open -g "$APP_PATH"

sleep 1
APP_PROCESS_PATH="${APP_PATH}/Contents/MacOS/cmux"
if ps -ax -o command= | grep -F "$APP_PROCESS_PATH" | grep -v grep >/dev/null 2>&1; then
  echo "Release launch status:"
  echo "  running: ${APP_PROCESS_PATH}"
else
  echo "warning: Release app launch was requested, but no running process was observed for:" >&2
  echo "  ${APP_PROCESS_PATH}" >&2
fi
