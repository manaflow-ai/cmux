#!/usr/bin/env bash
set -euo pipefail

# A Release build shares the stable bundle id (com.cmuxterm.app). Launching it
# while the user's cmux is running would replace that app and drop its live
# agent sessions, so refuse unless explicitly allowed.
# This checkout's Release bundle, from its own build settings, so another
# checkout's Release build is never mistaken for ours.
own_release_app_path() {
  local settings
  # Keep going on failure so the caller reports it instead of set -e exiting silently.
  settings="$(xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Release -destination 'platform=macOS' \
    -skipPackageUpdates -showBuildSettings 2>&1)" || {
    echo "$settings" | tail -5 >&2
    return 0
  }
  # Only the cmux app target's block: the scheme also lists test targets.
  printf '%s\n' "$settings" | awk -F ' = ' '
    /^Build settings for action .* and target / { target = $0; sub(/.* and target /, "", target); sub(/:$/, "", target) }
    target == "cmux" && /^ *BUILT_PRODUCTS_DIR = / && dir == "" { dir = $2 }
    target == "cmux" && /^ *FULL_PRODUCT_NAME = / && name == "" { name = $2 }
    END { if (dir != "" && name ~ /\.app$/) print dir "/" name }'
}

# Every stable-id cmux except this script's own Release build. Other Release
# builds count too: launching ours would replace them just the same.
running_stable_other_than() {
  local own_path="${1:-}"
  local running
  running="$(pgrep -fl "cmux\.app/Contents/MacOS/cmux( |$)" 2>/dev/null || true)"
  if [[ -n "$own_path" ]]; then
    running="$(printf '%s\n' "$running" | grep -vF "${own_path}/Contents/MacOS/cmux" || true)"
  fi
  printf '%s' "$running" | sed '/^$/d'
}

refuse_if_stable_running() {
  local other
  other="$(running_stable_other_than "${1:-}")"
  if [[ -n "$other" && "${CMUX_ALLOW_REPLACING_RUNNING_CMUX:-}" != "1" ]]; then
    echo "error: the user's cmux (stable bundle id com.cmuxterm.app) is running:" >&2
    echo "$other" | sed 's/^/  /' >&2
    echo "A Release build shares that id and would replace it. Use ./scripts/reload.sh --tag <slug>," >&2
    echo "or have the user quit cmux first (CMUX_ALLOW_REPLACING_RUNNING_CMUX=1 overrides)." >&2
    exit 1
  fi
}

# Fail before the build, and again right before launching.
OWN_APP_PATH="$(own_release_app_path)"
if [[ -z "$OWN_APP_PATH" ]]; then
  echo "error: could not resolve this checkout's Release app path from xcodebuild -showBuildSettings" >&2
  exit 1
fi
refuse_if_stable_running "$OWN_APP_PATH"
OPEN_ENV_ARGS=()
if [[ "${CMUX_ALLOW_REPLACING_RUNNING_CMUX:-}" == "1" ]]; then
  # open(1) does not pass the caller's environment to the app.
  OPEN_ENV_ARGS=(--env CMUX_ALLOW_REPLACING_RUNNING_CMUX=1)
fi

# cmux-next's web bundles are build output (cx-vn5); the app's verify phase needs them.
if [[ -x scripts/cmux-next/build-web-bundles.sh ]]; then
  scripts/cmux-next/build-web-bundles.sh
fi
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Release -destination 'platform=macOS' build
APP_PATH="$OWN_APP_PATH"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "cmux.app not found at ${APP_PATH}" >&2
  exit 1
fi

echo "Release app:"
echo "  ${APP_PATH}"
refuse_if_stable_running "$APP_PATH"

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
