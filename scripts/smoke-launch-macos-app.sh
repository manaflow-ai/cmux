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
OPEN_LOG="$(mktemp /tmp/cmux-smoke-open.XXXXXX.log)"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
  fi
  rm -f "$OPEN_LOG"
}
trap cleanup EXIT

find_app_pid() {
  pgrep -f "$EXECUTABLE_PATH" 2>/dev/null | head -n 1 || true
}

echo "==> smoke launching $APP_PATH"
/usr/bin/open -n -g "$APP_PATH" --args -ApplePersistenceIgnoreState YES >"$OPEN_LOG" 2>&1 &
OPEN_PID=$!

deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  APP_PID="$(find_app_pid)"
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
  if [[ -s "$OPEN_LOG" ]]; then
    cat "$OPEN_LOG" >&2
  fi
  exit 1
fi

for _ in $(seq 1 "$STABLE_SECONDS"); do
  sleep 1
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "error: app process $APP_PID exited during ${STABLE_SECONDS}s launch smoke" >&2
    if [[ -s "$OPEN_LOG" ]]; then
      cat "$OPEN_LOG" >&2
    fi
    LOG_NAME="$(printf '%s' "$BUNDLE_ID" | sed -E 's/[^A-Za-z0-9._-]/-/g')"
    STARTUP_LOG="$HOME/Library/Logs/cmux/startup-${LOG_NAME}.log"
    if [[ -f "$STARTUP_LOG" ]]; then
      echo "startup breadcrumbs:" >&2
      tail -n 80 "$STARTUP_LOG" >&2 || true
    fi
    /usr/bin/log show --last 2m --style compact --predicate "process == '$EXECUTABLE_NAME' OR eventMessage CONTAINS '$BUNDLE_ID'" 2>/dev/null | tail -n 160 >&2 || true
    exit 1
  fi
done

echo "==> launch smoke OK: pid $APP_PID stayed alive for ${STABLE_SECONDS}s"
