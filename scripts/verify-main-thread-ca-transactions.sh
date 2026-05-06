#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-${CMUX_APP_PATH:-}}"
TAG="${CMUX_TAG:-ca-main-thread}"
SOCKET_PATH="${CMUX_SOCKET_PATH:-/tmp/cmux-debug-${TAG}.sock}"
LOG_PATH="${CMUX_CA_ASSERT_LOG:-/tmp/cmux-ca-main-thread-${TAG}.log}"
HOLD_SECONDS="${CMUX_CA_ASSERT_HOLD_SECONDS:-8}"
APP_PID_FILE="${CMUX_CA_ASSERT_PID_FILE:-/tmp/cmux-ca-main-thread-${TAG}.pid}"

if [ -z "$APP_PATH" ]; then
  echo "usage: CMUX_APP_PATH=/path/to/cmux.app $0" >&2
  echo "   or: $0 /path/to/cmux.app" >&2
  exit 2
fi

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: app bundle not found: $APP_PATH" >&2
  exit 2
fi

APP_BASENAME="$(basename "$APP_PATH")"
if [ "$APP_BASENAME" = "cmux DEV.app" ] && [ "${CMUX_ALLOW_UNTAGGED_CA_REGRESSION:-0}" != "1" ]; then
  echo "ERROR: refusing to launch untagged cmux DEV.app without CMUX_ALLOW_UNTAGGED_CA_REGRESSION=1" >&2
  exit 2
fi

BINARY="$APP_PATH/Contents/MacOS/cmux DEV"
if [ ! -x "$BINARY" ]; then
  BINARY="$APP_PATH/Contents/MacOS/cmux"
fi

if [ ! -x "$BINARY" ]; then
  echo "ERROR: cmux executable not found in $APP_PATH" >&2
  exit 2
fi

APP_PID=""

kill_recorded_app() {
  if [ ! -f "$APP_PID_FILE" ]; then
    return
  fi

  local recorded_pid
  recorded_pid="$(cat "$APP_PID_FILE" 2>/dev/null || true)"
  case "$recorded_pid" in
    ""|*[!0-9]*)
      rm -f "$APP_PID_FILE"
      return
      ;;
  esac

  local args
  args="$(ps -p "$recorded_pid" -o args= 2>/dev/null || true)"
  if [ -n "$args" ] && [[ "$args" == *"$BINARY"* ]]; then
    kill "$recorded_pid" >/dev/null 2>&1 || true
  fi
  rm -f "$APP_PID_FILE"
}

cleanup() {
  if [ -n "$APP_PID" ]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$SOCKET_PATH" "$APP_PID_FILE"
}
trap cleanup EXIT

kill_recorded_app
rm -f "$SOCKET_PATH" "$LOG_PATH"

CA_ASSERT_MAIN_THREAD_TRANSACTIONS=1 \
CA_DEBUG_TRANSACTIONS=1 \
CMUX_UI_TEST_MODE=1 \
CMUX_DISABLE_SESSION_RESTORE=1 \
CMUX_SOCKET_ENABLE=1 \
CMUX_SOCKET_MODE=automation \
CMUX_TAG="$TAG" \
CMUX_SOCKET_PATH="$SOCKET_PATH" \
CMUX_ALLOW_SOCKET_OVERRIDE=1 \
"$BINARY" >"$LOG_PATH" 2>&1 &
APP_PID=$!
echo "$APP_PID" >"$APP_PID_FILE"

deadline=$((SECONDS + HOLD_SECONDS))
socket_ready=0
while [ "$SECONDS" -lt "$deadline" ]; do
  if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
    wait "$APP_PID" >/dev/null 2>&1 || true
    echo "FAIL: cmux exited while CA_ASSERT_MAIN_THREAD_TRANSACTIONS=1 was active" >&2
    echo "--- app log tail ($LOG_PATH) ---" >&2
    tail -80 "$LOG_PATH" >&2 2>/dev/null || true
    exit 1
  fi

  if [ -S "$SOCKET_PATH" ]; then
    socket_ready=1
  fi
  sleep 0.25
done

if [ "$socket_ready" -ne 1 ]; then
  echo "FAIL: cmux stayed alive but did not create its socket at $SOCKET_PATH" >&2
  echo "--- app log tail ($LOG_PATH) ---" >&2
  tail -80 "$LOG_PATH" >&2 2>/dev/null || true
  exit 1
fi

if grep -E "uncommitted CATransaction|implicit transaction wasn't created|CoreAnimation.*thread|CATransaction.*thread" "$LOG_PATH" >/dev/null 2>&1; then
  echo "FAIL: CoreAnimation reported a worker-thread transaction" >&2
  echo "--- app log tail ($LOG_PATH) ---" >&2
  tail -80 "$LOG_PATH" >&2 2>/dev/null || true
  exit 1
fi

echo "PASS: cmux startup survived CoreAnimation main-thread transaction assertions"
