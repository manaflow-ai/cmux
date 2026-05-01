#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/measure-desktop-ios-anchormux-latency.sh <tag>

Builds a tagged desktop app and simulator app, attaches iOS to the same live
Anchormux session, then measures:
  - desktop local echo latency with iOS connected
  - desktop to iOS visible render latency
  - iOS local echo latency
  - iOS to desktop visible render latency
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

TAG="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANITIZED_TAG="$(echo "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
EVENT_PATH="/tmp/cmux-anchormux-latency-${SANITIZED_TAG}.jsonl"
TEST_LOG="/tmp/cmux-anchormux-latency-${SANITIZED_TAG}-ios.log"
OPEN_LOG="/tmp/cmux-anchormux-latency-${SANITIZED_TAG}-open.log"
DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData/cmux-${SANITIZED_TAG}-latency-ios"
DESKTOP_LOCAL_MAX_MS="${CMUX_DESKTOP_LOCAL_LATENCY_MAX_MS:-200}"
DESKTOP_TO_IOS_MAX_MS="${CMUX_DESKTOP_TO_IOS_LATENCY_MAX_MS:-1500}"
IOS_LOCAL_MAX_MS="${CMUX_IOS_LOCAL_LATENCY_MAX_MS:-1200}"
IOS_TO_DESKTOP_MAX_MS="${CMUX_IOS_TO_DESKTOP_LATENCY_MAX_MS:-1200}"

READY_TOKEN="IOS_LATENCY_$(date +%s)"
DESKTOP_TOKEN="DESKTOP_LATENCY_$(date +%s)"

cd "$ROOT"
rm -f "$EVENT_PATH" "$TEST_LOG" "$OPEN_LOG"

if [[ ! -e "$ROOT/GhosttyKit.xcframework" && -d "$ROOT/ghostty/macos/GhosttyKit.xcframework" ]]; then
  ln -sfn "$ROOT/ghostty/macos/GhosttyKit.xcframework" "$ROOT/GhosttyKit.xcframework"
fi

OPEN_OUTPUT="$(
  CMUX_LIVE_ANCHORMUX_READY_TOKEN="$READY_TOKEN" \
  CMUX_LIVE_ANCHORMUX_DESKTOP_TOKEN="$DESKTOP_TOKEN" \
  ./scripts/open-desktop-ios-anchormux-live.sh "$TAG" | tee "$OPEN_LOG"
)"

DESKTOP_APP="$(printf '%s\n' "$OPEN_OUTPUT" | awk -F'=' '/^desktop_app=/ {print $2; exit}')"
APP_SOCKET="$(printf '%s\n' "$OPEN_OUTPUT" | awk -F'=' '/^desktop_automation_socket=/ {print $2; exit}')"
SURFACE_ID="$(printf '%s\n' "$OPEN_OUTPUT" | awk -F'=' '/^desktop_surface=/ {print $2; exit}')"
RELAY_PORT="$(printf '%s\n' "$OPEN_OUTPUT" | awk -F'=' '/^relay_port=/ {print $2; exit}')"
SIM_ID="$(printf '%s\n' "$OPEN_OUTPUT" | awk -F'=' '/^simulator_id=/ {print $2; exit}')"

if [[ -z "$DESKTOP_APP" || -z "$APP_SOCKET" || -z "$SURFACE_ID" || -z "$RELAY_PORT" || -z "$SIM_ID" ]]; then
  echo "error: failed to parse live launcher output" >&2
  exit 1
fi

xcrun simctl spawn "$SIM_ID" launchctl setenv CMUX_LIVE_ANCHORMUX_EVENT_PATH "$EVENT_PATH" >/dev/null 2>&1 || true

(
  cd "$ROOT/ios"
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_HOST="127.0.0.1" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_PORT="$RELAY_PORT" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_SESSION_ID="$SURFACE_ID" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_READY_TOKEN="$READY_TOKEN" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_DESKTOP_TOKEN="$DESKTOP_TOKEN" \
  SIMCTL_CHILD_CMUX_LIVE_ANCHORMUX_EVENT_PATH="$EVENT_PATH" \
  xcodebuild test \
    -project cmux.xcodeproj \
    -scheme cmux \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination "platform=iOS Simulator,id=${SIM_ID}" \
    -only-testing:cmuxTests/AnchormuxLiveLatencyTests
) >"$TEST_LOG" 2>&1 &
TEST_PID=$!

cleanup() {
  kill "$TEST_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

append_event() {
  local event_name="$1"
  local event_epoch_ms="$2"
  local event_token="${3:-}"
  python3 - "$EVENT_PATH" "$event_name" "$event_epoch_ms" "$event_token" <<'PY'
import json
import os
import sys

path, name, epoch_ms, token = sys.argv[1:]
payload = {
    "name": name,
    "epoch_ms": int(epoch_ms),
}
if token:
    payload["token"] = token
line = json.dumps(payload) + "\n"
with open(path, "a", encoding="utf-8") as handle:
    handle.write(line)
PY
}

wait_for_event() {
  local event_name="$1"
  python3 - "$EVENT_PATH" "$event_name" <<'PY'
import json
import os
import sys
import time

path, target = sys.argv[1:]
deadline = time.time() + 120.0
while time.time() < deadline:
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    payload = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if payload.get("name") == target:
                    print(payload.get("epoch_ms", ""))
                    raise SystemExit(0)
    time.sleep(0.05)
raise SystemExit(f"timed out waiting for event {target} in {path}")
PY
}

measure_desktop_local() {
  python3 - "$ROOT" "$APP_SOCKET" "$SURFACE_ID" "$DESKTOP_TOKEN" <<'PY'
import json
import os
import sys
import time

root, app_socket, surface_id, token = sys.argv[1:]
sys.path.insert(0, os.path.join(root, "tests_v2"))
from cmux import cmux  # type: ignore

client = cmux(app_socket)
client.connect()
try:
    client.activate_app()
    client.focus_surface_by_panel(surface_id)
    baseline = client.read_terminal_text(surface_id)
    start_ms = int(time.time() * 1000)
    client.simulate_type(f"echo {token}\n")
    deadline = time.time() + 20.0
    while time.time() < deadline:
        text = client.read_terminal_text(surface_id)
        if token in text and token not in baseline:
            print(json.dumps({
                "desktop_send_ms": start_ms,
                "desktop_local_seen_ms": int(time.time() * 1000),
            }))
            raise SystemExit(0)
        time.sleep(0.02)
    raise SystemExit(f"timed out waiting for desktop token {token!r}")
finally:
    client.close()
PY
}

measure_ios_seen_on_desktop() {
  python3 - "$ROOT" "$APP_SOCKET" "$SURFACE_ID" "$READY_TOKEN" <<'PY'
import json
import os
import sys
import time

root, app_socket, surface_id, token = sys.argv[1:]
sys.path.insert(0, os.path.join(root, "tests_v2"))
from cmux import cmux  # type: ignore

client = cmux(app_socket)
client.connect()
try:
    deadline = time.time() + 30.0
    while time.time() < deadline:
        text = client.read_terminal_text(surface_id)
        if token in text:
            print(json.dumps({
                "ios_seen_on_desktop_ms": int(time.time() * 1000),
            }))
            raise SystemExit(0)
        time.sleep(0.02)
    raise SystemExit(f"timed out waiting for iOS token {token!r} on desktop")
finally:
    client.close()
PY
}

CONNECTED_MS="$(wait_for_event connected)"
if [[ -z "$CONNECTED_MS" ]]; then
  echo "error: live latency test never connected" >&2
  cat "$TEST_LOG" >&2 || true
  exit 1
fi

DESKTOP_JSON="$(measure_desktop_local)"
DESKTOP_SEND_MS="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["desktop_send_ms"])' <<<"$DESKTOP_JSON")"
DESKTOP_LOCAL_SEEN_MS="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["desktop_local_seen_ms"])' <<<"$DESKTOP_JSON")"
append_event desktop_send "$DESKTOP_SEND_MS" "$DESKTOP_TOKEN"
append_event desktop_local_seen "$DESKTOP_LOCAL_SEEN_MS" "$DESKTOP_TOKEN"
DESKTOP_SEEN_ON_IOS_MS="$(wait_for_event desktop_seen_on_ios)"
IOS_SEND_MS="$(wait_for_event ios_send)"
IOS_JSON="$(measure_ios_seen_on_desktop)"
IOS_SEEN_ON_DESKTOP_MS="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["ios_seen_on_desktop_ms"])' <<<"$IOS_JSON")"
append_event ios_seen_on_desktop "$IOS_SEEN_ON_DESKTOP_MS" "$READY_TOKEN"
IOS_RENDER_MS="$(wait_for_event ios_render)"

wait "$TEST_PID"
trap - EXIT

DESKTOP_LOCAL_MS=$((DESKTOP_LOCAL_SEEN_MS - DESKTOP_SEND_MS))
DESKTOP_TO_IOS_MS=$((DESKTOP_SEEN_ON_IOS_MS - DESKTOP_SEND_MS))
IOS_LOCAL_MS=$((IOS_RENDER_MS - IOS_SEND_MS))
IOS_TO_DESKTOP_MS=$((IOS_SEEN_ON_DESKTOP_MS - IOS_SEND_MS))

printf 'desktop_app=%s\n' "$DESKTOP_APP"
printf 'desktop_tag=%s\n' "$TAG"
printf 'desktop_surface=%s\n' "$SURFACE_ID"
printf 'simulator_id=%s\n' "$SIM_ID"
printf 'desktop_local_ms=%s\n' "$DESKTOP_LOCAL_MS"
printf 'desktop_to_ios_ms=%s\n' "$DESKTOP_TO_IOS_MS"
printf 'ios_local_ms=%s\n' "$IOS_LOCAL_MS"
printf 'ios_to_desktop_ms=%s\n' "$IOS_TO_DESKTOP_MS"

if (( DESKTOP_LOCAL_MS > DESKTOP_LOCAL_MAX_MS )); then
  echo "error: desktop local latency ${DESKTOP_LOCAL_MS}ms exceeds ${DESKTOP_LOCAL_MAX_MS}ms" >&2
  exit 1
fi
if (( DESKTOP_TO_IOS_MS > DESKTOP_TO_IOS_MAX_MS )); then
  echo "error: desktop->iOS latency ${DESKTOP_TO_IOS_MS}ms exceeds ${DESKTOP_TO_IOS_MAX_MS}ms" >&2
  exit 1
fi
if (( IOS_LOCAL_MS > IOS_LOCAL_MAX_MS )); then
  echo "error: iOS local latency ${IOS_LOCAL_MS}ms exceeds ${IOS_LOCAL_MAX_MS}ms" >&2
  exit 1
fi
if (( IOS_TO_DESKTOP_MS > IOS_TO_DESKTOP_MAX_MS )); then
  echo "error: iOS->desktop latency ${IOS_TO_DESKTOP_MS}ms exceeds ${IOS_TO_DESKTOP_MAX_MS}ms" >&2
  exit 1
fi

printf 'PASS: desktop and iOS Anchormux latency is within thresholds\n'
