#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/verify-ios-macos-workspace-sync.sh <tag>

Launches a tagged macOS cmux app, seeds three desktop workspaces, runs the iOS
simulator UI test against that exact desktop daemon port, and verifies text
typed in iOS reaches the desktop terminal.
EOF
}

sanitize_path() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="iossync"
  fi
  echo "$cleaned"
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

TAG="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANITIZED_TAG="$(sanitize_path "$TAG")"
MAC_RELOAD_LOG="/tmp/cmux-ios-macos-sync-${SANITIZED_TAG}-mac-reload.log"
MAC_LAUNCH_LOG="/tmp/cmux-ios-macos-sync-${SANITIZED_TAG}-mac-launch.log"
IOS_TEST_LOG="/tmp/cmux-ios-macos-sync-${SANITIZED_TAG}-ios-test.log"
RESULT_BUNDLE="/tmp/cmux-ios-macos-sync-${SANITIZED_TAG}.xcresult"
IOS_DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/cmux-${SANITIZED_TAG}-ios-sync"
WSPORT_FILE="/tmp/cmux-debug-${SANITIZED_TAG}.wsport"
INPUT_TOKEN="IOS_TO_MAC_${SANITIZED_TAG}_$(date +%s)"

cd "$ROOT"

if ! ./scripts/reload.sh --tag "$TAG" >"$MAC_RELOAD_LOG" 2>&1; then
  echo "error: macOS tagged reload failed" >&2
  cat "$MAC_RELOAD_LOG" >&2
  exit 1
fi
if ! LAUNCH_OUTPUT="$("./scripts/launch-tagged-automation.sh" "$TAG" --wait-socket 30 2>&1 | tee "$MAC_LAUNCH_LOG")"; then
  echo "error: tagged automation launch failed" >&2
  cat "$MAC_LAUNCH_LOG" >&2
  exit 1
fi

APP_SOCKET="$(printf '%s\n' "$LAUNCH_OUTPUT" | awk -F': ' '/^socket:/ {print $2; exit}')"
DAEMON_SOCKET="$(printf '%s\n' "$LAUNCH_OUTPUT" | awk -F': ' '/^cmuxd_socket:/ {print $2; exit}')"
if [[ -z "$APP_SOCKET" || -z "$DAEMON_SOCKET" ]]; then
  echo "error: failed to parse tagged launch output" >&2
  exit 1
fi

SEED_JSON="$(
  APP_SOCKET="$APP_SOCKET" DAEMON_SOCKET="$DAEMON_SOCKET" SANITIZED_TAG="$SANITIZED_TAG" python3 - "$ROOT" <<'PY'
import json
import os
import socket
import sys
import time

root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "tests_v2"))
from cmux import cmux  # type: ignore

app_socket = os.environ["APP_SOCKET"]
daemon_socket = os.environ["DAEMON_SOCKET"]
tag = os.environ["SANITIZED_TAG"]
titles = [
    f"ios-sync-a-{tag}",
    f"ios-sync-b-{tag}",
    f"ios-sync-c-{tag}",
]


def wait_for(predicate, timeout=30.0, interval=0.1, label="condition"):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            value = predicate()
            if value:
                return value
            last = value
        except Exception as exc:
            last = exc
        time.sleep(interval)
    raise SystemExit(f"timed out waiting for {label}: {last!r}")


def daemon_call(method, params=None):
    payload = json.dumps({
        "id": 1,
        "method": method,
        "params": params or {},
    }, separators=(",", ":")).encode("utf-8") + b"\n"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(daemon_socket)
        sock.sendall(payload)
        data = b""
        while b"\n" not in data:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
    return json.loads(data.decode("utf-8"))


client = cmux(app_socket)
client.connect()
try:
    wait_for(lambda: client.current_workspace(), label="desktop current workspace")
    base_workspace = client.current_workspace()

    for _, workspace_id, _, _ in list(client.list_workspaces()):
        if workspace_id != base_workspace:
            client.close_workspace(workspace_id)
    wait_for(lambda: len(client.list_workspaces()) == 1, label="single desktop workspace")

    workspace_ids = [base_workspace]
    client.rename_workspace(titles[0], base_workspace)
    for title in titles[1:]:
        workspace_id = client.new_workspace()
        workspace_ids.append(workspace_id)
        client.rename_workspace(title, workspace_id)

    surfaces = []
    for workspace_id in workspace_ids:
        def first_surface(workspace_id=workspace_id):
            rows = client.list_surfaces(workspace_id)
            return rows[0][1] if rows else None
        surfaces.append(wait_for(first_surface, label=f"surface for {workspace_id}"))

    expected = set(titles)
    def daemon_synced():
        response = daemon_call("workspace.list")
        rows = response.get("result", {}).get("workspaces", [])
        row_titles = [row.get("title", "") for row in rows]
        row_sessions = [row.get("session_id") for row in rows]
        if len(rows) == len(titles) and set(row_titles) == expected and all(row_sessions):
            return response
        return {"titles": row_titles, "sessions": row_sessions, "count": len(rows)}

    daemon_response = wait_for(daemon_synced, timeout=45.0, label="daemon workspace sync")
    print(json.dumps({
        "titles": titles,
        "workspace_ids": workspace_ids,
        "surface_ids": surfaces,
        "daemon": daemon_response.get("result", {}),
    }, separators=(",", ":")))
finally:
    client.close()
PY
)"

EXPECTED_TITLES="$(python3 -c 'import json,sys; print("|".join(json.loads(sys.stdin.read())["titles"]))' <<<"$SEED_JSON")"
FIRST_SURFACE="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["surface_ids"][0])' <<<"$SEED_JSON")"

deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
  if [[ -s "$WSPORT_FILE" ]]; then
    break
  fi
  sleep 0.1
done
if [[ ! -s "$WSPORT_FILE" ]]; then
  echo "error: macOS mobile WebSocket port file never appeared at $WSPORT_FILE" >&2
  exit 1
fi
WSPORT="$(cat "$WSPORT_FILE")"

SIM_ID="${CMUX_IOS_MAC_SYNC_SIMULATOR_ID:-}"
if [[ -z "$SIM_ID" ]]; then
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
for runtime_devices in devices.values():
    for device in runtime_devices:
        if "iPhone" in device.get("name", "") and device.get("isAvailable", False):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit("no available iPhone simulator found")
'
  )"
fi

xcrun simctl boot "$SIM_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIM_ID" -b >/dev/null
xcrun simctl terminate "$SIM_ID" dev.cmux.app.dev >/dev/null 2>&1 || true
xcrun simctl uninstall "$SIM_ID" dev.cmux.app.dev >/dev/null 2>&1 || true

(
  cd "$ROOT/ios"
  xcodegen generate >/dev/null
  rm -rf "$RESULT_BUNDLE"
  CMUX_IOS_MAC_SYNC_HOST="127.0.0.1" \
  CMUX_IOS_MAC_SYNC_WS_PORT="$WSPORT" \
  CMUX_IOS_MAC_SYNC_EXPECTED_TITLES="$EXPECTED_TITLES" \
  CMUX_IOS_MAC_SYNC_INPUT_TOKEN="$INPUT_TOKEN" \
  CMUX_IOS_MAC_SYNC_HOST_HOME="$HOME" \
  xcodebuild test \
    -project cmux.xcodeproj \
    -scheme cmux \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=${SIM_ID}" \
    -derivedDataPath "$IOS_DERIVED_DATA" \
    -resultBundlePath "$RESULT_BUNDLE" \
    -maximum-test-execution-time-allowance 180 \
    -only-testing:cmuxUITests/IOSMacWorkspaceSyncUITests/testDesktopWorkspacesMirrorAndTerminalInputRoundTrips
) >"$IOS_TEST_LOG" 2>&1 || {
  echo "error: iOS macOS workspace sync UI test failed" >&2
  cat "$IOS_TEST_LOG" >&2
  exit 1
}

APP_SOCKET="$APP_SOCKET" FIRST_SURFACE="$FIRST_SURFACE" INPUT_TOKEN="$INPUT_TOKEN" python3 - "$ROOT" <<'PY'
import os
import sys
import time

root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "tests_v2"))
from cmux import cmux  # type: ignore

client = cmux(os.environ["APP_SOCKET"])
client.connect()
try:
    deadline = time.time() + 30.0
    last_text = ""
    while time.time() < deadline:
        last_text = client.read_terminal_text(os.environ["FIRST_SURFACE"])
        if os.environ["INPUT_TOKEN"] in last_text:
            print("desktop_saw_ios_input_token=true")
            raise SystemExit(0)
        time.sleep(0.1)
    raise SystemExit(f"desktop never saw iOS input token {os.environ['INPUT_TOKEN']!r}: {last_text!r}")
finally:
    client.close()
PY

printf 'desktop_tag=%s\n' "$TAG"
printf 'ios_simulator=%s\n' "$SIM_ID"
printf 'ws_port=%s\n' "$WSPORT"
printf 'expected_titles=%s\n' "$EXPECTED_TITLES"
printf 'mac_reload_log=%s\n' "$MAC_RELOAD_LOG"
printf 'mac_launch_log=%s\n' "$MAC_LAUNCH_LOG"
printf 'ios_test_log=%s\n' "$IOS_TEST_LOG"
printf 'result_bundle=%s\n' "$RESULT_BUNDLE"
printf 'PASS: iOS and macOS workspace sync converged and terminal input round-tripped\n'
