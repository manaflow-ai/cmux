#!/usr/bin/env bash
set -euo pipefail

# A Release build shares the stable bundle id (com.cmuxterm.app). Launching it
# while the user's cmux is running would replace that app and drop its live
# agent sessions, so refuse unless explicitly allowed.
running_stable_outside_derived_data() {
  pgrep -fl "cmux.app/Contents/MacOS/cmux$" 2>/dev/null | grep -vF "/Build/Products/Release/cmux.app/Contents/MacOS/cmux" || true
}

OTHER_STABLE="$(running_stable_outside_derived_data)"
if [[ -n "$OTHER_STABLE" && "${CMUX_ALLOW_REPLACING_RUNNING_CMUX:-}" != "1" ]]; then
  echo "error: the user's cmux (stable bundle id com.cmuxterm.app) is running:" >&2
  echo "$OTHER_STABLE" | sed 's/^/  /' >&2
  echo "A Release build shares that id and would replace it. Use ./scripts/reload.sh --tag <slug>," >&2
  echo "or have the user quit cmux first (CMUX_ALLOW_REPLACING_RUNNING_CMUX=1 overrides)." >&2
  exit 1
fi
OPEN_ENV_ARGS=()
if [[ "${CMUX_ALLOW_REPLACING_RUNNING_CMUX:-}" == "1" ]]; then
  # open(1) does not pass the caller's environment to the app.
  OPEN_ENV_ARGS=(--env CMUX_ALLOW_REPLACING_RUNNING_CMUX=1)
fi

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

pkill -f "${APP_PATH}/Contents/MacOS/cmux" || true
sleep 0.2

# Dev shells (including CI/Codex) often force-disable paging by exporting these.
# Don't leak that into cmux, otherwise `git diff` won't page even with PAGER=less.
env -u GIT_PAGER -u GH_PAGER open -g ${OPEN_ENV_ARGS[@]+"${OPEN_ENV_ARGS[@]}"} "$APP_PATH"

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
