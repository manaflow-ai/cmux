#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <app-path>" >&2
  exit 2
fi

APP_PATH="$1"
if [[ ! -d "$APP_PATH/Contents" ]]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
STARTUP_TIMEOUT_SECONDS="${CMUX_SMOKE_STARTUP_TIMEOUT_SECONDS:-10}"
STABLE_SECONDS="${CMUX_SMOKE_STABLE_SECONDS:-5}"
OPEN_LOG="$(mktemp -t cmux-smoke-open.XXXXXX)"
APP_PID=""
PREEXISTING_PIDS="$(pgrep -f "$EXECUTABLE_PATH" 2>/dev/null || true)"
DEBUG_LOGS="${CMUX_SMOKE_DEBUG_LOGS:-0}"
ALLOW_UNSUPPORTED_GUI="${CMUX_SMOKE_ALLOW_UNSUPPORTED_GUI:-0}"
DIRECT_EXEC="${CMUX_SMOKE_DIRECT_EXEC:-0}"
DISABLE_ICON_PERSISTENCE_KEY="cmuxDisableBundleIconPersistence"

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
  fi
  /usr/bin/defaults delete "$BUNDLE_ID" "$DISABLE_ICON_PERSISTENCE_KEY" >/dev/null 2>&1 || true
  rm -f "$OPEN_LOG"
}
trap cleanup EXIT

find_new_app_pid() {
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if ! printf '%s\n' "$PREEXISTING_PIDS" | grep -Fxq "$pid"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done < <(pgrep -f "$EXECUTABLE_PATH" 2>/dev/null || true)
  return 1
}

dump_open_log() {
  if [[ ! -s "$OPEN_LOG" ]]; then
    return
  fi
  if [[ "$DEBUG_LOGS" == "1" ]]; then
    cat "$OPEN_LOG" >&2
  else
    echo "open launcher output captured (set CMUX_SMOKE_DEBUG_LOGS=1 to print)" >&2
  fi
}

dump_system_log() {
  if [[ "$DEBUG_LOGS" == "1" ]]; then
    /usr/bin/log show --last 2m --style compact --predicate "process == '$EXECUTABLE_NAME' OR eventMessage CONTAINS '$BUNDLE_ID'" 2>/dev/null | tail -n 160 >&2 || true
  else
    echo "system log capture skipped (set CMUX_SMOKE_DEBUG_LOGS=1 to print)" >&2
  fi
}

open_log_indicates_unsupported_gui() {
  [[ -s "$OPEN_LOG" ]] || return 1
  grep -Fq 'OSLaunchdErrorDomain Code=125' "$OPEN_LOG" \
    && grep -Fq 'Domain does not support specified action' "$OPEN_LOG"
}

echo "==> smoke launching $APP_PATH"
# The Dock tile plugin can run in the Dock process, so seed the shared app
# defaults domain before LaunchServices starts the app.
/usr/bin/defaults write "$BUNDLE_ID" "$DISABLE_ICON_PERSISTENCE_KEY" -bool YES
if [[ "$DIRECT_EXEC" == "1" ]]; then
  CMUX_UI_TEST_MODE="${CMUX_UI_TEST_MODE:-1}" \
    "$EXECUTABLE_PATH" -ApplePersistenceIgnoreState YES --cmux-disable-bundle-icon-persistence >"$OPEN_LOG" 2>&1 &
else
  CMUX_UI_TEST_MODE="${CMUX_UI_TEST_MODE:-1}" \
    /usr/bin/open -n -g "$APP_PATH" --args -ApplePersistenceIgnoreState YES --cmux-disable-bundle-icon-persistence >"$OPEN_LOG" 2>&1 &
fi
OPEN_PID=$!

# CI-only LaunchServices smoke: open returns before the app process is visible.
# Use bounded polling to wait for registration, then a bounded liveness window.
deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  if [[ "$DIRECT_EXEC" == "1" ]]; then
    APP_PID="$OPEN_PID"
  else
    APP_PID="$(find_new_app_pid || true)"
  fi
  if [[ -n "$APP_PID" ]]; then
    break
  fi
  if ! kill -0 "$OPEN_PID" 2>/dev/null; then
    wait "$OPEN_PID" || true
  fi
  sleep 0.2
done

if [[ -z "$APP_PID" ]]; then
  echo "error: app process did not appear for bundle $BUNDLE_ID within ${STARTUP_TIMEOUT_SECONDS}s" >&2
  if [[ "$ALLOW_UNSUPPORTED_GUI" == "1" ]] && open_log_indicates_unsupported_gui; then
    echo "warning: GUI launch smoke unsupported on this runner, skipping launch-only check" >&2
    dump_open_log
    exit 0
  fi
  dump_open_log
  exit 1
fi

for _ in $(seq 1 "$STABLE_SECONDS"); do
  sleep 1
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "error: app process $APP_PID exited during ${STABLE_SECONDS}s launch smoke" >&2
    dump_open_log
    LOG_NAME="$(printf '%s' "$BUNDLE_ID" | sed -E 's/[^A-Za-z0-9._-]/-/g')"
    STARTUP_LOG="$HOME/Library/Logs/cmux/startup-${LOG_NAME}.log"
    if [[ -f "$STARTUP_LOG" ]]; then
      echo "startup breadcrumbs:" >&2
      tail -n 80 "$STARTUP_LOG" >&2 || true
    fi
    dump_system_log
    exit 1
  fi
done

echo "==> launch smoke OK: pid $APP_PID stayed alive for ${STABLE_SECONDS}s"
