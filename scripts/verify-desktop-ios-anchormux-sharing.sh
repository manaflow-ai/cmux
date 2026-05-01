#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/verify-desktop-ios-anchormux-sharing.sh <tag>

Builds a tagged desktop cmux app, launches it with automation, relays the
desktop daemon Unix socket to localhost TCP, then runs the live iOS simulator
Anchormux sharing test against that exact desktop session.
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

TAG="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANITIZED_TAG="$(echo "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData/cmux-${SANITIZED_TAG}"
APP_LAUNCH_LOG="/tmp/cmux-desktop-ios-anchormux-${SANITIZED_TAG}-launch.log"
RELAY_LOG="/tmp/cmux-desktop-ios-anchormux-${SANITIZED_TAG}-relay.log"
TEST_LOG="/tmp/cmux-desktop-ios-anchormux-${SANITIZED_TAG}-ios.log"
RELOAD_LOG="/tmp/cmux-desktop-ios-anchormux-${SANITIZED_TAG}-reload.log"
CONFIG_PATH="/tmp/cmux-live-anchormux-${SANITIZED_TAG}.json"
DAEMON_BIN="$ROOT/daemon/remote/zig/zig-out/bin/cmuxd-remote"

RELAY_PID=""
TEST_PID=""

cleanup() {
  if [[ -n "${SIM_ID:-}" ]]; then
    xcrun simctl spawn "$SIM_ID" launchctl unsetenv CMUX_LIVE_ANCHORMUX_HOST >/dev/null 2>&1 || true
    xcrun simctl spawn "$SIM_ID" launchctl unsetenv CMUX_LIVE_ANCHORMUX_PORT >/dev/null 2>&1 || true
    xcrun simctl spawn "$SIM_ID" launchctl unsetenv CMUX_LIVE_ANCHORMUX_SESSION_ID >/dev/null 2>&1 || true
    xcrun simctl spawn "$SIM_ID" launchctl unsetenv CMUX_LIVE_ANCHORMUX_READY_TOKEN >/dev/null 2>&1 || true
    xcrun simctl spawn "$SIM_ID" launchctl unsetenv CMUX_LIVE_ANCHORMUX_DESKTOP_TOKEN >/dev/null 2>&1 || true
    xcrun simctl spawn "$SIM_ID" launchctl unsetenv CMUX_LIVE_ANCHORMUX_APP_SOCKET >/dev/null 2>&1 || true
  fi
  rm -f "$CONFIG_PATH"
  if [[ -n "$TEST_PID" ]]; then
    kill "$TEST_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$RELAY_PID" ]]; then
    kill "$RELAY_PID" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

cd "$ROOT"
./scripts/reload.sh --tag "$TAG" >"$RELOAD_LOG" 2>&1

LAUNCH_OUTPUT="$("./scripts/launch-tagged-automation.sh" "$TAG" --wait-socket 20)"
printf '%s\n' "$LAUNCH_OUTPUT" | tee "$APP_LAUNCH_LOG"

APP_SOCKET="$(printf '%s\n' "$LAUNCH_OUTPUT" | awk -F': ' '/^socket:/ {print $2; exit}')"
DAEMON_SOCKET="$(printf '%s\n' "$LAUNCH_OUTPUT" | awk -F': ' '/^cmuxd_socket:/ {print $2; exit}')"

if [[ -z "$APP_SOCKET" || -z "$DAEMON_SOCKET" ]]; then
  echo "error: failed to parse launch output" >&2
  exit 1
fi

if [[ ! -S "$APP_SOCKET" ]]; then
  echo "error: app automation socket missing at $APP_SOCKET" >&2
  exit 1
fi

if [[ ! -S "$DAEMON_SOCKET" ]]; then
  echo "error: desktop daemon socket missing at $DAEMON_SOCKET" >&2
  exit 1
fi

RELAY_PORT="$(
  python3 - <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"

python3 "$ROOT/scripts/unix_socket_tcp_relay.py" "$DAEMON_SOCKET" "$RELAY_PORT" >"$RELAY_LOG" 2>&1 &
RELAY_PID="$!"

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
            print("relay_ready")
            raise SystemExit(0)
    except OSError as exc:
        last = exc
        time.sleep(0.1)
raise SystemExit(f"relay never became reachable: {last}")
PY

SESSION_INFO="$(
  APP_SOCKET="$APP_SOCKET" python3 - "$ROOT" <<'PY'
import os
import sys
import time

root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "tests_v2"))
from cmux import cmux, cmuxError  # type: ignore

client = cmux(os.environ["APP_SOCKET"])
client.connect()
try:
    deadline = time.time() + 20.0
    last = None
    while time.time() < deadline:
        try:
            client.current_workspace()
            break
        except Exception as exc:
            last = exc
            time.sleep(0.1)
    else:
        raise SystemExit(f"app never reached workspace-ready state: {last}")

    workspace_id = client.new_workspace()
    client.select_workspace(workspace_id)

    deadline = time.time() + 20.0
    last_surfaces = []
    while time.time() < deadline:
        last_surfaces = client.list_surfaces(workspace_id)
        if last_surfaces:
            surface_id = last_surfaces[0][1]
            print(f"workspace={workspace_id}")
            print(f"surface={surface_id}")
            raise SystemExit(0)
        time.sleep(0.1)

    raise SystemExit(f"workspace {workspace_id} never exposed a surface: {last_surfaces!r}")
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

deadline=$((SECONDS + 20))
while (( SECONDS < deadline )); do
  if "$DAEMON_BIN" amux status "$SURFACE_ID" --socket "$DAEMON_SOCKET" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

if ! "$DAEMON_BIN" amux status "$SURFACE_ID" --socket "$DAEMON_SOCKET" >/dev/null 2>&1; then
  echo "error: desktop session $SURFACE_ID never appeared in daemon" >&2
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

READY_TOKEN="IOS_READY_$(date +%s)"
DESKTOP_TOKEN="DESKTOP_READY_$(date +%s)"

python3 - "$CONFIG_PATH" "$RELAY_PORT" "$SURFACE_ID" "$READY_TOKEN" "$DESKTOP_TOKEN" <<'PY'
import json
import sys

path, port, session_id, ready_token, desktop_token = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "host": "127.0.0.1",
            "port": int(port),
            "session_id": session_id,
            "ready_token": ready_token,
            "desktop_token": desktop_token,
        },
        handle,
    )
PY

xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_LIVE_ANCHORMUX_HOST "127.0.0.1"
xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_LIVE_ANCHORMUX_PORT "$RELAY_PORT"
xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_LIVE_ANCHORMUX_SESSION_ID "$SURFACE_ID"
xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_LIVE_ANCHORMUX_READY_TOKEN "$READY_TOKEN"
xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_LIVE_ANCHORMUX_DESKTOP_TOKEN "$DESKTOP_TOKEN"
xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_LIVE_ANCHORMUX_APP_SOCKET "$APP_SOCKET"

APP_SOCKET="$APP_SOCKET" SURFACE_ID="$SURFACE_ID" DESKTOP_TOKEN="$DESKTOP_TOKEN" python3 - "$ROOT" <<'PY'
import os
import sys
import time

root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "tests_v2"))
from cmux import cmux  # type: ignore

client = cmux(os.environ["APP_SOCKET"])
client.connect()
try:
    client.send_surface(os.environ["SURFACE_ID"], f"echo {os.environ['DESKTOP_TOKEN']}")
    client.send_key_surface(os.environ["SURFACE_ID"], "enter")

    deadline = time.time() + 20.0
    last_text = ""
    while time.time() < deadline:
        last_text = client.read_terminal_text(os.environ["SURFACE_ID"])
        if os.environ["DESKTOP_TOKEN"] in last_text:
            print("desktop_backlog_token_seeded")
            raise SystemExit(0)
        time.sleep(0.1)
    raise SystemExit(f"timed out waiting for desktop token in desktop workspace: {last_text!r}")
finally:
    client.close()
PY

(
  cd "$ROOT/ios"
  CMUX_LIVE_ANCHORMUX_HOST="127.0.0.1" \
  CMUX_LIVE_ANCHORMUX_PORT="$RELAY_PORT" \
  CMUX_LIVE_ANCHORMUX_SESSION_ID="$SURFACE_ID" \
  CMUX_LIVE_ANCHORMUX_READY_TOKEN="$READY_TOKEN" \
  CMUX_LIVE_ANCHORMUX_DESKTOP_TOKEN="$DESKTOP_TOKEN" \
  CMUX_LIVE_ANCHORMUX_APP_SOCKET="$APP_SOCKET" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_HOST="127.0.0.1" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_PORT="$RELAY_PORT" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_SESSION_ID="$SURFACE_ID" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_READY_TOKEN="$READY_TOKEN" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_DESKTOP_TOKEN="$DESKTOP_TOKEN" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_APP_SOCKET="$APP_SOCKET" \
  xcodebuild test \
    -project cmux.xcodeproj \
    -scheme cmux \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination "platform=iOS Simulator,id=${SIM_ID}" \
    -only-testing:cmuxTests/AnchormuxLiveSharingTests
) >"$TEST_LOG" 2>&1 &
TEST_PID="$!"

APP_SOCKET="$APP_SOCKET" SURFACE_ID="$SURFACE_ID" READY_TOKEN="$READY_TOKEN" python3 - "$ROOT" <<'PY'
import os
import sys
import time

root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "tests_v2"))
from cmux import cmux, cmuxError  # type: ignore

client = cmux(os.environ["APP_SOCKET"])
client.connect()
try:
    deadline = time.time() + 240.0
    last_text = ""
    while time.time() < deadline:
        last_text = client.read_terminal_text(os.environ["SURFACE_ID"])
        if os.environ["READY_TOKEN"] in last_text:
            print("desktop_ready_token_seen")
            raise SystemExit(0)
        time.sleep(0.1)
    raise SystemExit(f"timed out waiting for ready token in desktop workspace: {last_text!r}")
finally:
    client.close()
PY

if ! wait "$TEST_PID"; then
  echo "error: live iOS Anchormux test failed" >&2
  cat "$TEST_LOG" >&2
  exit 1
fi
TEST_PID=""

printf 'desktop_workspace=%s\n' "$WORKSPACE_ID"
printf 'desktop_surface=%s\n' "$SURFACE_ID"
printf 'relay_port=%s\n' "$RELAY_PORT"
printf 'app_socket=%s\n' "$APP_SOCKET"
printf 'daemon_socket=%s\n' "$DAEMON_SOCKET"
printf 'reload_log=%s\n' "$RELOAD_LOG"
printf 'relay_log=%s\n' "$RELAY_LOG"
printf 'ios_test_log=%s\n' "$TEST_LOG"
printf 'PASS: desktop cmux and simulator iOS cmux shared the same Anchormux session\n'
