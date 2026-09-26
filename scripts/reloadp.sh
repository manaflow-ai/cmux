#!/usr/bin/env bash
set -euo pipefail

# A Release build shares the stable bundle id (com.cmuxterm.app). Launching it
# while the user's cmux is running would replace that app and drop its live
# agent sessions, so refuse unless explicitly allowed.
running_stable_other_than() {
  local own_path="$1"
  pgrep -fl "cmux.app/Contents/MacOS/cmux$" 2>/dev/null | grep -vF "${own_path:-/nonexistent}/Contents/MacOS/cmux" || true
}

xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Release -destination 'platform=macOS' build
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

OTHER_STABLE="$(running_stable_other_than "$APP_PATH")"
if [[ -n "$OTHER_STABLE" && "${CMUX_ALLOW_REPLACING_RUNNING_CMUX:-}" != "1" ]]; then
  echo "error: another cmux with the stable bundle id is running:" >&2
  echo "$OTHER_STABLE" | sed 's/^/  /' >&2
  echo "Launching this Release build would replace it. Use ./scripts/reload.sh --tag <slug>," >&2
  echo "or have the user quit cmux first (CMUX_ALLOW_REPLACING_RUNNING_CMUX=1 overrides)." >&2
  exit 1
fi
pkill -f "${APP_PATH}/Contents/MacOS/cmux" || true
sleep 0.2

# Dev shells (including CI/Codex) often force-disable paging by exporting these.
# Don't leak that into cmux, otherwise `git diff` won't page even with PAGER=less.
env -u GIT_PAGER -u GH_PAGER open -g "$APP_PATH"

APP_PROCESS_PATH="${APP_PATH}/Contents/MacOS/cmux"
ATTEMPT=0
MAX_ATTEMPTS=20
while [[ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]]; do
  if pgrep -f "$APP_PROCESS_PATH" >/dev/null 2>&1; then
    echo "Release launch status:"
    echo "  running: ${APP_PROCESS_PATH}"
    exit 0
  fi
  ATTEMPT=$((ATTEMPT + 1))
  sleep 0.25
done

echo "warning: Release app launch was requested, but no running process was observed for:" >&2
echo "  ${APP_PROCESS_PATH}" >&2
