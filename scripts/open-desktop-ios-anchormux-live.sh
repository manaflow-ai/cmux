#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/open-desktop-ios-anchormux-live.sh <tag> [--auto-open-first]

Builds a tagged desktop cmux app, creates a fresh desktop Anchormux session,
starts a localhost relay for the live desktop daemon, and reloads the iOS
simulator app so it shows the new shared desktop session as a live Anchormux
inbox item.
EOF
}

sanitize_path() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="anchormux"
  fi
  echo "$cleaned"
}

AUTO_OPEN_FIRST=0
if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

TAG="$1"
if [[ $# -eq 2 ]]; then
  if [[ "$2" != "--auto-open-first" ]]; then
    usage
    exit 1
  fi
  AUTO_OPEN_FIRST=1
fi
IOS_TAG="${TAG}-ios"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANITIZED_TAG="$(sanitize_path "$TAG")"
IOS_GHOSTTY_THEME="${CMUX_LIVE_ANCHORMUX_IOS_GHOSTTY_THEME:-}"
READY_TOKEN="${CMUX_LIVE_ANCHORMUX_READY_TOKEN:-}"
DESKTOP_TOKEN="${CMUX_LIVE_ANCHORMUX_DESKTOP_TOKEN:-}"
RELAY_PORT_FILE="/tmp/cmux-live-anchormux-${SANITIZED_TAG}.port"
RELAY_PID_FILE="/tmp/cmux-live-anchormux-${SANITIZED_TAG}.pid"
RELAY_LOG="/tmp/cmux-live-anchormux-${SANITIZED_TAG}-relay.log"
SYNC_PID_FILE="/tmp/cmux-live-anchormux-${SANITIZED_TAG}-sync.pid"
SYNC_LOG="/tmp/cmux-live-anchormux-${SANITIZED_TAG}-sync.log"
CONFIG_PATH="/tmp/cmux-live-anchormux-${SANITIZED_TAG}.json"
DESKTOP_RELOAD_LOG="/tmp/cmux-live-anchormux-${SANITIZED_TAG}-desktop-reload.log"
IOS_RELOAD_LOG="/tmp/cmux-live-anchormux-${SANITIZED_TAG}-ios-reload.log"
IOS_THEME_CONFIG_RELATIVE_PATH="Library/Application Support/ghostty/config.ghostty"

ensure_local_ghosttykit_link() {
  local link_path="$ROOT/GhosttyKit.xcframework"
  local local_xcframework="$ROOT/ghostty/macos/GhosttyKit.xcframework"

  if [[ -e "$link_path" ]]; then
    return 0
  fi
  if [[ -d "$local_xcframework" ]]; then
    ln -sfn "$local_xcframework" "$link_path"
  fi
}

wait_for_process_pattern_exit() {
  local pattern="$1"
  local timeout_s="${2:-10}"
  local deadline=$((SECONDS + timeout_s))
  while (( SECONDS < deadline )); do
    if ! pgrep -f "$pattern" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

cd "$ROOT"
ensure_local_ghosttykit_link

pkill -x Simulator >/dev/null 2>&1 || true
for app_pattern in \
  "cmux DEV .*\\.app/Contents/MacOS/cmux DEV" \
  "cmuxd-remote serve --unix --socket .*/cmuxd-dev-.*\\.sock" \
  "sync_live_anchormux_workspaces.py"
do
  pkill -f "$app_pattern" >/dev/null 2>&1 || true
done
wait_for_process_pattern_exit "cmux DEV .*\\.app/Contents/MacOS/cmux DEV" 10 || true
wait_for_process_pattern_exit "cmuxd-remote serve --unix --socket .*/cmuxd-dev-.*\\.sock" 10 || true
wait_for_process_pattern_exit "sync_live_anchormux_workspaces.py" 10 || true

CMUX_SKIP_ZIG_BUILD=1 ./scripts/reload.sh --tag "$TAG" >"$DESKTOP_RELOAD_LOG" 2>&1

LAUNCH_OUTPUT="$(CMUX_SKIP_ZIG_BUILD=1 "./scripts/launch-tagged-automation.sh" "$TAG" --wait-socket 20)"
printf '%s\n' "$LAUNCH_OUTPUT"

DESKTOP_APP="$(printf '%s\n' "$LAUNCH_OUTPUT" | awk -F': ' '/^app:/ {print $2; exit}')"
APP_SOCKET="$(printf '%s\n' "$LAUNCH_OUTPUT" | awk -F': ' '/^socket:/ {print $2; exit}')"
DAEMON_SOCKET="$(printf '%s\n' "$LAUNCH_OUTPUT" | awk -F': ' '/^cmuxd_socket:/ {print $2; exit}')"

if [[ -z "$DESKTOP_APP" || -z "$APP_SOCKET" || -z "$DAEMON_SOCKET" ]]; then
  echo "error: failed to parse desktop launch output" >&2
  exit 1
fi

SESSION_INFO="$(
  APP_SOCKET="$APP_SOCKET" SANITIZED_TAG="$SANITIZED_TAG" python3 - "$ROOT" <<'PY'
import os
import sys
import time

root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "tests_v2"))
from cmux import cmux  # type: ignore

client = cmux(os.environ["APP_SOCKET"])
client.connect()
try:
    deadline = time.time() + 20.0
    while time.time() < deadline:
        try:
            client.current_workspace()
            break
        except Exception:
            time.sleep(0.1)
    else:
        raise SystemExit("desktop app never reached workspace-ready state")

    workspace_id = client.current_workspace()
    deadline = time.time() + 20.0
    last_surfaces = []
    while time.time() < deadline:
        last_surfaces = client.list_surfaces(workspace_id)
        if last_surfaces:
            focused = [surface_id for _, surface_id, is_focused in last_surfaces if is_focused]
            surface_id = focused[0] if focused else last_surfaces[0][1]
            break
        time.sleep(0.1)
    else:
        raise SystemExit(f"workspace {workspace_id} never exposed a surface: {last_surfaces!r}")

    print(f"workspace={workspace_id}")
    print(f"surface={surface_id}")
finally:
    client.close()
PY
)"

WORKSPACE_ID="$(printf '%s\n' "$SESSION_INFO" | awk -F'=' '/^workspace=/ {print $2; exit}')"
SURFACE_ID="$(printf '%s\n' "$SESSION_INFO" | awk -F'=' '/^surface=/ {print $2; exit}')"

if [[ -z "$WORKSPACE_ID" || -z "$SURFACE_ID" ]]; then
  echo "error: failed to create desktop workspace or surface" >&2
  printf '%s\n' "$SESSION_INFO" >&2
  exit 1
fi

DAEMON_BIN="$ROOT/daemon/remote/zig/zig-out/bin/cmuxd-remote"
if ! "$DAEMON_BIN" amux status "$SURFACE_ID" --socket "$DAEMON_SOCKET" >/dev/null 2>&1; then
  deadline=$((SECONDS + 20))
  while (( SECONDS < deadline )); do
    if "$DAEMON_BIN" amux status "$SURFACE_ID" --socket "$DAEMON_SOCKET" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
fi

if ! "$DAEMON_BIN" amux status "$SURFACE_ID" --socket "$DAEMON_SOCKET" >/dev/null 2>&1; then
  echo "error: desktop session $SURFACE_ID never appeared in daemon" >&2
  exit 1
fi

if [[ -f "$SYNC_PID_FILE" ]]; then
  OLD_SYNC_PID="$(cat "$SYNC_PID_FILE" 2>/dev/null || true)"
  if [[ -n "$OLD_SYNC_PID" ]]; then
    kill "$OLD_SYNC_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$SYNC_PID_FILE"
fi

if [[ -f "$RELAY_PID_FILE" ]]; then
  OLD_RELAY_PID="$(cat "$RELAY_PID_FILE" 2>/dev/null || true)"
  if [[ -n "$OLD_RELAY_PID" ]]; then
    kill "$OLD_RELAY_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$RELAY_PID_FILE"
fi

RELAY_PORT="$(
  python3 - <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"

printf '%s\n' "$RELAY_PORT" >"$RELAY_PORT_FILE"

python3 "$ROOT/scripts/unix_socket_tcp_relay.py" \
  "$DAEMON_SOCKET" \
  "$RELAY_PORT" \
  --daemonize \
  --pid-file "$RELAY_PID_FILE" \
  --log-file "$RELAY_LOG"

RELAY_PID="$(cat "$RELAY_PID_FILE" 2>/dev/null || true)"
if [[ -z "$RELAY_PID" ]]; then
  echo "error: relay failed to write pid file" >&2
  exit 1
fi

python3 - "$RELAY_PORT" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
deadline = time.time() + 10.0
last = None
while time.time() < deadline:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
            raise SystemExit(0)
    except OSError as exc:
        last = exc
        time.sleep(0.1)
raise SystemExit(f"relay never became reachable: {last}")
PY

SYNC_ARGS=(
  "$ROOT/scripts/sync_live_anchormux_workspaces.py"
  --app-socket "$APP_SOCKET"
  --config-path "$CONFIG_PATH"
  --relay-port "$RELAY_PORT"
  --machine-id "anchormux-live-${SANITIZED_TAG}"
)
if [[ "$AUTO_OPEN_FIRST" == "1" ]]; then
  SYNC_ARGS+=(--auto-open)
fi

python3 "${SYNC_ARGS[@]}" --once >"$SYNC_LOG" 2>&1
python3 "${SYNC_ARGS[@]}" \
  --daemonize \
  --pid-file "$SYNC_PID_FILE" \
  --log-file "$SYNC_LOG"

SYNC_PID="$(cat "$SYNC_PID_FILE" 2>/dev/null || true)"
if [[ -z "$SYNC_PID" ]]; then
  echo "error: sync worker failed to write pid file" >&2
  exit 1
fi

SIM_ID="$(
  xcrun simctl list devices available --json | python3 -c '
import json
import sys

devices = json.load(sys.stdin).get("devices", {})
for runtime_devices in devices.values():
    for device in runtime_devices:
        if device.get("name") == "iPhone 17 Pro" and device.get("isAvailable", False):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit("no available iPhone 17 Pro simulator found")
'
)"

xcrun simctl boot "$SIM_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIM_ID" -b >/dev/null
xcrun simctl terminate "$SIM_ID" dev.cmux.app.dev >/dev/null 2>&1 || true
xcrun simctl uninstall "$SIM_ID" dev.cmux.app.dev >/dev/null 2>&1 || true
rm -f "$CONFIG_PATH"

for key in \
  CMUX_LIVE_ANCHORMUX_ENABLED \
  CMUX_LIVE_ANCHORMUX_HOST \
  CMUX_LIVE_ANCHORMUX_PORT \
  CMUX_LIVE_ANCHORMUX_SESSION_ID \
  CMUX_LIVE_ANCHORMUX_CONFIG_PATH \
  CMUX_LIVE_ANCHORMUX_AUTO_OPEN_SESSION_ID \
  CMUX_LIVE_ANCHORMUX_READY_TOKEN \
  CMUX_LIVE_ANCHORMUX_DESKTOP_TOKEN \
  CMUX_LIVE_ANCHORMUX_MACHINE_ID \
  CMUX_LIVE_ANCHORMUX_APP_SOCKET \
  CMUX_GHOSTTY_CONFIG_PATH
do
  xcrun simctl spawn "$SIM_ID" launchctl unsetenv "$key" >/dev/null 2>&1 || true
done

xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_LIVE_ANCHORMUX_ENABLED "1"
xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_LIVE_ANCHORMUX_HOST "127.0.0.1"
xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_LIVE_ANCHORMUX_PORT "$RELAY_PORT"
xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_LIVE_ANCHORMUX_SESSION_ID "$SURFACE_ID"
xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_LIVE_ANCHORMUX_CONFIG_PATH "$CONFIG_PATH"
xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_LIVE_ANCHORMUX_MACHINE_ID "anchormux-live-${SANITIZED_TAG}"
xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_LIVE_ANCHORMUX_APP_SOCKET "$APP_SOCKET"
if [[ -n "$READY_TOKEN" ]]; then
  xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_LIVE_ANCHORMUX_READY_TOKEN "$READY_TOKEN"
fi
if [[ -n "$DESKTOP_TOKEN" ]]; then
  xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_LIVE_ANCHORMUX_DESKTOP_TOKEN "$DESKTOP_TOKEN"
fi
if [[ "$AUTO_OPEN_FIRST" == "1" ]]; then
  xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_LIVE_ANCHORMUX_AUTO_OPEN_SESSION_ID "$SURFACE_ID"
else
  xcrun simctl spawn "$SIM_ID" launchctl unsetenv CMUX_LIVE_ANCHORMUX_AUTO_OPEN_SESSION_ID >/dev/null 2>&1 || true
fi

(
  cd "$ROOT/ios"
  CMUX_LIVE_ANCHORMUX_ENABLED="1" \
  CMUX_LIVE_ANCHORMUX_HOST="127.0.0.1" \
  CMUX_LIVE_ANCHORMUX_PORT="$RELAY_PORT" \
  CMUX_LIVE_ANCHORMUX_SESSION_ID="$SURFACE_ID" \
  CMUX_LIVE_ANCHORMUX_CONFIG_PATH="$CONFIG_PATH" \
  CMUX_LIVE_ANCHORMUX_MACHINE_ID="anchormux-live-${SANITIZED_TAG}" \
  CMUX_LIVE_ANCHORMUX_APP_SOCKET="$APP_SOCKET" \
  CMUX_LIVE_ANCHORMUX_READY_TOKEN="$READY_TOKEN" \
  CMUX_LIVE_ANCHORMUX_DESKTOP_TOKEN="$DESKTOP_TOKEN" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_ENABLED="1" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_HOST="127.0.0.1" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_PORT="$RELAY_PORT" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_SESSION_ID="$SURFACE_ID" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_CONFIG_PATH="$CONFIG_PATH" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_MACHINE_ID="anchormux-live-${SANITIZED_TAG}" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_APP_SOCKET="$APP_SOCKET" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_READY_TOKEN="$READY_TOKEN" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_DESKTOP_TOKEN="$DESKTOP_TOKEN" \
  ./scripts/reload.sh --tag "$IOS_TAG"
) >"$IOS_RELOAD_LOG" 2>&1

if [[ -n "$IOS_GHOSTTY_THEME" ]]; then
  SIM_DATA_CONTAINER="$(xcrun simctl get_app_container "$SIM_ID" dev.cmux.app.dev data)"
  IOS_THEME_CONFIG_PATH="${SIM_DATA_CONTAINER}/${IOS_THEME_CONFIG_RELATIVE_PATH}"
  mkdir -p "$(dirname "$IOS_THEME_CONFIG_PATH")"
  printf 'theme = %s\n' "$IOS_GHOSTTY_THEME" > "$IOS_THEME_CONFIG_PATH"
  xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_GHOSTTY_CONFIG_PATH "$IOS_THEME_CONFIG_PATH"
  xcrun simctl terminate "$SIM_ID" dev.cmux.app.dev >/dev/null 2>&1 || true
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_ENABLED="1" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_HOST="127.0.0.1" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_PORT="$RELAY_PORT" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_SESSION_ID="$SURFACE_ID" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_CONFIG_PATH="$CONFIG_PATH" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_MACHINE_ID="anchormux-live-${SANITIZED_TAG}" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_APP_SOCKET="$APP_SOCKET" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_READY_TOKEN="$READY_TOKEN" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_DESKTOP_TOKEN="$DESKTOP_TOKEN" \
  SIMCTL_CHILD_CMUX_GHOSTTY_CONFIG_PATH="$IOS_THEME_CONFIG_PATH" \
  xcrun simctl launch "$SIM_ID" dev.cmux.app.dev >/dev/null
else
  xcrun simctl spawn "$SIM_ID" launchctl unsetenv CMUX_GHOSTTY_CONFIG_PATH >/dev/null 2>&1 || true
fi

printf 'desktop_app=%s\n' "$DESKTOP_APP"
printf 'desktop_tag=%s\n' "$TAG"
printf 'ios_tag=%s\n' "$IOS_TAG"
printf 'desktop_workspace=%s\n' "$WORKSPACE_ID"
printf 'desktop_surface=%s\n' "$SURFACE_ID"
printf 'desktop_automation_socket=%s\n' "$APP_SOCKET"
printf 'desktop_daemon_socket=%s\n' "$DAEMON_SOCKET"
printf 'relay_port=%s\n' "$RELAY_PORT"
printf 'relay_pid=%s\n' "$RELAY_PID"
printf 'relay_log=%s\n' "$RELAY_LOG"
printf 'sync_pid=%s\n' "$SYNC_PID"
printf 'sync_log=%s\n' "$SYNC_LOG"
printf 'config_path=%s\n' "$CONFIG_PATH"
printf 'desktop_reload_log=%s\n' "$DESKTOP_RELOAD_LOG"
printf 'ios_reload_log=%s\n' "$IOS_RELOAD_LOG"
printf 'simulator_id=%s\n' "$SIM_ID"
printf 'PASS: desktop and simulator are configured for the same Anchormux workspaces\n'
