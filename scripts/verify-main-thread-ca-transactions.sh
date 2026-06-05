#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-${CMUX_APP_PATH:-}}"
TAG="${CMUX_TAG:-ca-main-thread}"
SOCKET_PATH="${CMUX_CA_ASSERT_SOCKET_PATH:-/tmp/cmux-debug-${TAG}.sock}"
LOG_PATH="${CMUX_CA_ASSERT_LOG:-/tmp/cmux-ca-main-thread-${TAG}.log}"
HOLD_SECONDS="${CMUX_CA_ASSERT_HOLD_SECONDS:-8}"
READY_TIMEOUT_SECONDS="${CMUX_CA_ASSERT_READY_TIMEOUT_SECONDS:-60}"
APP_PID_FILE="${CMUX_CA_ASSERT_PID_FILE:-/tmp/cmux-ca-main-thread-${TAG}.pid}"
DIAGNOSTICS_PATH="${CMUX_CA_ASSERT_DIAGNOSTICS:-/tmp/cmux-ca-main-thread-${TAG}.diagnostics.json}"
APP_LAUNCHER_PID=""

if [ -z "$APP_PATH" ]; then
  echo "usage: CMUX_APP_PATH=/path/to/cmux.app $0" >&2
  echo "   or: $0 /path/to/cmux.app" >&2
  echo "optional: CMUX_CA_ASSERT_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock" >&2
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

BUNDLE_ID="$(
  plutil -extract CFBundleIdentifier raw -o - "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
)"
startup_log_component() {
  printf '%s' "${BUNDLE_ID:-unknown}" | sed -E 's/[^A-Za-z0-9._-]/-/g' | cut -c 1-160
}
STARTUP_LOG_PATH="${CMUX_CA_ASSERT_STARTUP_LOG:-$HOME/Library/Logs/cmux/startup-$(startup_log_component).log}"

BINARY="$APP_PATH/Contents/MacOS/cmux DEV"
if [ ! -x "$BINARY" ]; then
  BINARY="$APP_PATH/Contents/MacOS/cmux"
fi

if [ ! -x "$BINARY" ]; then
  echo "ERROR: cmux executable not found in $APP_PATH" >&2
  exit 2
fi

APP_PID=""

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

kill_stale_ci_apps() {
  local should_kill="${CMUX_CA_ASSERT_KILL_STALE_APPS:-${GITHUB_ACTIONS:-0}}"
  is_truthy "$should_kill" || return 0

  local pids
  pids="$(pgrep -x "cmux DEV" 2>/dev/null || true)"
  [ -n "$pids" ] || return 0

  local pid args target_pids
  target_pids=""
  for pid in $pids; do
    args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    if [[ "$args" == *"$BINARY"* ]]; then
      target_pids="${target_pids}${pid}"$'\n'
      kill "$pid" >/dev/null 2>&1 || true
    fi
  done
  [ -n "$target_pids" ] || return 0

  local deadline=$((SECONDS + 5))
  while [ "$SECONDS" -lt "$deadline" ]; do
    local any_alive=0
    for pid in $target_pids; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        any_alive=1
      fi
    done
    [ "$any_alive" -eq 0 ] && return
    sleep 0.25
  done

  for pid in $target_pids; do
    args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    if [[ "$args" == *"$BINARY"* ]]; then
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  done
}

dump_diagnostics() {
  echo "--- app log tail ($LOG_PATH) ---" >&2
  tail -80 "$LOG_PATH" >&2 2>/dev/null || true
  if [ -f "$STARTUP_LOG_PATH" ]; then
    echo "--- startup breadcrumbs ($STARTUP_LOG_PATH) ---" >&2
    tail -80 "$STARTUP_LOG_PATH" >&2 2>/dev/null || true
  fi
  if [ -f "$DIAGNOSTICS_PATH" ]; then
    echo "--- ui test diagnostics ($DIAGNOSTICS_PATH) ---" >&2
    cat "$DIAGNOSTICS_PATH" >&2 2>/dev/null || true
  fi
  echo "--- matching cmux processes ---" >&2
  ps -ax -o pid=,stat=,command= | grep "/Contents/MacOS/cmux DEV" | grep -v grep >&2 || true
}

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
  if [ -n "$APP_LAUNCHER_PID" ]; then
    kill "$APP_LAUNCHER_PID" >/dev/null 2>&1 || true
    wait "$APP_LAUNCHER_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$SOCKET_PATH" "$APP_PID_FILE" "$DIAGNOSTICS_PATH"
}
trap cleanup EXIT

kill_recorded_app
kill_stale_ci_apps
rm -f "$SOCKET_PATH" "$LOG_PATH" "$STARTUP_LOG_PATH" "$DIAGNOSTICS_PATH"

APP_ENV=(
  "CA_ASSERT_MAIN_THREAD_TRANSACTIONS=1"
  "CA_DEBUG_TRANSACTIONS=1"
  "CMUX_STARTUP_BREADCRUMBS=1"
  "CMUX_UI_TEST_MODE=1"
  "CMUX_UI_TEST_SOCKET_SANITY=1"
  "CMUX_UI_TEST_DIAGNOSTICS_PATH=$DIAGNOSTICS_PATH"
  "CMUX_DISABLE_SESSION_RESTORE=1"
  "CMUX_SOCKET_ENABLE=1"
  "CMUX_SOCKET_MODE=automation"
  "CMUX_TAG=$TAG"
  "CMUX_SOCKET_PATH=$SOCKET_PATH"
  "CMUX_ALLOW_SOCKET_OVERRIDE=1"
)

find_launched_app_pid() {
  local pids pid args
  pids="$(pgrep -x "cmux DEV" 2>/dev/null || true)"
  for pid in $pids; do
    args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    if [[ "$args" == *"$BINARY"* ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

refresh_app_pid_from_process_table() {
  local resolved
  resolved="$(find_launched_app_pid || true)"
  [ -n "$resolved" ] || return 1
  APP_PID="$resolved"
  echo "$APP_PID" >"$APP_PID_FILE"
  return 0
}

launch_app() {
  local current_user gui_user gui_uid
  current_user="$(id -un)"
  gui_user="$(stat -f %Su /dev/console 2>/dev/null || true)"
  if [ -n "$gui_user" ] &&
     [ "$gui_user" != "root" ] &&
     gui_uid="$(id -u "$gui_user" 2>/dev/null)" &&
     command -v sudo >/dev/null 2>&1 &&
     sudo -n true 2>/dev/null; then
    echo "Launching cmux in console GUI bootstrap for $gui_user ($gui_uid); current user: $current_user"
    sudo -n launchctl asuser "$gui_uid" \
      sudo -n -H -u "$gui_user" /usr/bin/env "${APP_ENV[@]}" "$BINARY" >"$LOG_PATH" 2>&1 &
  else
    echo "Launching cmux in current bootstrap"
    env "${APP_ENV[@]}" "$BINARY" >"$LOG_PATH" 2>&1 &
  fi
  APP_LAUNCHER_PID=$!

  local resolve_deadline=$((SECONDS + 5))
  while [ "$SECONDS" -lt "$resolve_deadline" ]; do
    if refresh_app_pid_from_process_table; then
      return
    fi
    sleep 0.25
  done
}

launch_app

wait_for_app_alive() {
  if [ -z "$APP_PID" ] || ! kill -0 "$APP_PID" >/dev/null 2>&1; then
    refresh_app_pid_from_process_table || true
  fi

  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    return
  fi

  if [ -n "$APP_LAUNCHER_PID" ] && kill -0 "$APP_LAUNCHER_PID" >/dev/null 2>&1; then
    return
  fi

  if [ -n "$APP_PID" ]; then
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$APP_LAUNCHER_PID" ]; then
    wait "$APP_LAUNCHER_PID" >/dev/null 2>&1 || true
  fi
    echo "FAIL: cmux exited while CA_ASSERT_MAIN_THREAD_TRANSACTIONS=1 was active" >&2
    dump_diagnostics
    exit 1
}

ready_deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
socket_ready=0
while [ "$SECONDS" -lt "$ready_deadline" ]; do
  wait_for_app_alive
  if [ -S "$SOCKET_PATH" ]; then
    socket_ready=1
    break
  fi
  sleep 0.25
done

if [ "$socket_ready" -ne 1 ]; then
  echo "FAIL: cmux stayed alive but did not create its socket at $SOCKET_PATH" >&2
  dump_diagnostics
  exit 1
fi

hold_deadline=$((SECONDS + HOLD_SECONDS))
while [ "$SECONDS" -lt "$hold_deadline" ]; do
  wait_for_app_alive
  sleep 0.25
done

if grep -E "uncommitted CATransaction|implicit transaction wasn't created|CoreAnimation.*thread|CATransaction.*thread" "$LOG_PATH" >/dev/null 2>&1; then
  echo "FAIL: CoreAnimation reported a worker-thread transaction" >&2
  dump_diagnostics
  exit 1
fi

echo "PASS: cmux startup survived CoreAnimation main-thread transaction assertions"
