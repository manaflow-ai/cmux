#!/usr/bin/env bash
set -euo pipefail

BUILD_TAG="${BUILD_TAG:?BUILD_TAG is required}"
DEVICE_FAMILY="${DEVICE_FAMILY:-iphone}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$PWD/artifact}"
SYNC_MARKER="${SYNC_MARKER:-cmux-real-sync-video}"
DEV_STACK_AUTH_TOKEN="${CMUX_MOBILE_DEV_STACK_AUTH_TOKEN:-cmux-cloud-sync-video-token}"

mkdir -p "$ARTIFACT_DIR"

phase() {
  echo "==> $*"
}

run_with_timeout() {
  local seconds="$1"
  shift
  python3 - "$seconds" "$@" <<'PY'
import subprocess
import sys

timeout = float(sys.argv[1])
cmd = sys.argv[2:]
try:
    raise SystemExit(subprocess.run(cmd, timeout=timeout).returncode)
except subprocess.TimeoutExpired:
    print(f"command timed out after {timeout:g}s: {' '.join(cmd)}", file=sys.stderr)
    raise SystemExit(124)
PY
}

sanitize_tag() {
  local raw="$1"
  local cleaned
  cleaned="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  [[ -n "$cleaned" ]] || cleaned="dev"
  printf '%s' "$cleaned"
}

sanitize_bundle() {
  local raw="$1"
  local cleaned
  cleaned="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g')"
  [[ -n "$cleaned" ]] || cleaned="dev"
  printf '%s' "$cleaned"
}

TAG_SLUG="$(sanitize_tag "$BUILD_TAG")"
TAG_BUNDLE="$(sanitize_bundle "$BUILD_TAG")"
MAC_BUNDLE_ID="com.cmuxterm.app.debug.${TAG_BUNDLE}"
IOS_BUNDLE_ID="dev.cmux.ios.${TAG_SLUG}"
SOCKET_PATH="/tmp/cmux-debug-${TAG_SLUG}.sock"
MAC_RAW_VIDEO="$ARTIFACT_DIR/cmux-macos-${BUILD_TAG}.mp4"
IOS_RAW_VIDEO="$ARTIFACT_DIR/cmux-ios-${BUILD_TAG}.mp4"
FINAL_VIDEO="$ARTIFACT_DIR/cmux-real-sync-left-right-${BUILD_TAG}.mp4"
MAC_RECORD_LOG="$ARTIFACT_DIR/macos-record.log"
MAC_FRAME_DIR="$ARTIFACT_DIR/macos-frames"
IOS_RECORD_LOG="$ARTIFACT_DIR/ios-record.log"
IOS_SIMULATOR_LOG="$ARTIFACT_DIR/ios-simulator.log"
IOS_SEEDED_DEFAULTS="$ARTIFACT_DIR/ios-seeded-defaults.txt"
METADATA_PATH="$ARTIFACT_DIR/metadata.json"

MAC_RECORDER_PID=""
IOS_RECORDER_PID=""
IOS_LOG_PID=""
SIMULATOR_ID=""
SIMULATOR_CREATED="0"

stop_pid_bounded() {
  local pid="$1"
  local signal="${2:-INT}"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi
  kill "-$signal" "$pid" >/dev/null 2>&1 || true
  for _ in $(seq 1 25); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      wait "$pid" >/dev/null 2>&1 || true
      return 0
    fi
    sleep 0.2
  done
  kill -KILL "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
}

cleanup() {
  set +e
  stop_pid_bounded "$MAC_RECORDER_PID" INT
  stop_pid_bounded "$IOS_RECORDER_PID" INT
  stop_pid_bounded "$IOS_LOG_PID" INT
  if [[ -n "$SIMULATOR_ID" ]]; then
    xcrun simctl terminate "$SIMULATOR_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
    if [[ "$SIMULATOR_CREATED" == "1" ]]; then
      xcrun simctl delete "$SIMULATOR_ID" >/dev/null 2>&1 || true
    fi
  fi
  osascript -e "tell application id \"$MAC_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  pkill -f "cmux DEV ${TAG_SLUG}.app/Contents/MacOS/cmux DEV" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_ffmpeg() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    brew install ffmpeg
  fi
  command -v ffmpeg >/dev/null 2>&1
}

select_simulator() {
  python3 - "$DEVICE_FAMILY" <<'PY'
import json
import shlex
import subprocess
import sys

family = sys.argv[1]
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
devices = [
    device
    for runtimes in data.get("devices", {}).values()
    for device in runtimes
    if device.get("isAvailable", True)
]
prefix = "iPad" if family == "ipad" else "iPhone"
preferred = ["iPad Pro 13-inch (M4)", "iPad Air 13-inch (M3)"] if family == "ipad" else ["iPhone 17", "iPhone 16"]
selected = next((d for name in preferred for d in devices if d.get("name") == name), None)
selected = selected or next((d for d in devices if d.get("name", "").startswith(prefix)), None)
created = False
if selected is None:
    runtimes_data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "available", "-j"]))
    runtimes = [
        runtime for runtime in runtimes_data.get("runtimes", [])
        if runtime.get("isAvailable", True)
        and (runtime.get("platform") == "iOS" or runtime.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS"))
    ]
    if not runtimes:
        raise SystemExit(f"No available iOS simulator runtime for {family}")
    runtime = sorted(runtimes, key=lambda r: tuple(int(p) for p in r.get("version", "0").split(".") if p.isdigit()), reverse=True)[0]
    types_data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devicetypes", "-j"]))
    types = [device_type for device_type in types_data.get("devicetypes", []) if device_type.get("name", "").startswith(prefix)]
    device_type = next((d for name in preferred for d in types if d.get("name") == name), None) or next(iter(types), None)
    if device_type is None:
        raise SystemExit(f"No available {prefix} simulator device type")
    udid = subprocess.check_output([
        "xcrun", "simctl", "create", f"cmux Real Video {device_type['name']}",
        device_type["identifier"], runtime["identifier"],
    ], text=True).strip()
    selected = {"udid": udid, "name": f"cmux Real Video {device_type['name']}"}
    created = True
print(f"SIMULATOR_ID={shlex.quote(selected['udid'])}")
print(f"SIMULATOR_NAME={shlex.quote(selected['name'])}")
print(f"SIMULATOR_CREATED={'1' if created else '0'}")
PY
}

wait_for_socket() {
  phase "waiting for tagged socket $SOCKET_PATH"
  for _ in $(seq 1 120); do
    if [[ -S "$SOCKET_PATH" ]]; then
      phase "tagged socket is ready"
      return 0
    fi
    sleep 0.5
  done
  echo "Tagged cmux socket did not appear: $SOCKET_PATH" >&2
  return 1
}

cmux_tagged() {
  CMUX_QUIET=1 CMUX_TAG="$BUILD_TAG" scripts/cmux-debug-cli.sh "$@"
}

json_field() {
  python3 -c '
import json
import sys

key = sys.argv[1]
data = json.load(sys.stdin)
value = data.get(key)
if value is None:
    value = data.get(key.replace("_id", "_ref"))
if value is None:
    raise SystemExit(1)
print(value)
' "$1"
}

mint_attach_url() {
  local workspace_id="$1"
  local terminal_id="$2"
  local payload
  local params
  params="$(python3 - "$workspace_id" "$terminal_id" <<'PY'
import json
import sys
print(json.dumps({
    "ttl_seconds": 900,
    "workspace_id": sys.argv[1],
    "terminal_id": sys.argv[2],
    "route_kind": "debug_loopback",
}, separators=(",", ":")))
PY
)"
  for _ in $(seq 1 40); do
    payload="$(cmux_tagged rpc mobile.attach_ticket.create "$params" 2>/dev/null || true)"
    if [[ -n "$payload" ]]; then
      REPO_ROOT="$PWD" PAYLOAD="$payload" node --input-type=module <<'NODE'
import path from "node:path";
import { pathToFileURL } from "node:url";

const { buildAttachURL } = await import(
  pathToFileURL(path.join(process.env.REPO_ROOT, "scripts", "lib", "attach-url.mjs")).href
);
const { attachURL } = buildAttachURL(JSON.parse(process.env.PAYLOAD), { routeKind: "debug_loopback" });
process.stdout.write(attachURL);
NODE
      return 0
    fi
    sleep 0.5
  done
  return 1
}

start_macos_recording() {
  rm -rf "$MAC_FRAME_DIR"
  mkdir -p "$MAC_FRAME_DIR"
  : > "$MAC_RECORD_LOG"
  (
    set +e
    i=0
    failures=0
    while true; do
      frame="$(printf "%s/frame-%05d.png" "$MAC_FRAME_DIR" "$i")"
      label="$(printf "sync-%05d" "$i")"
      params="$(python3 - "$label" <<'PY'
import json
import sys
print(json.dumps({"label": sys.argv[1]}, separators=(",", ":")))
PY
)"
      payload="$(cmux_tagged rpc debug.window.screenshot "$params" 2>>"$MAC_RECORD_LOG")"
      snapshot_path="$(printf '%s\n' "$payload" | json_field path 2>/dev/null)"
      if [[ -n "$snapshot_path" && -f "$snapshot_path" ]]; then
        cp "$snapshot_path" "$frame"
        failures=0
      else
        failures=$((failures + 1))
        echo "debug.window.screenshot failed payload=$payload" >&2
        if [[ "$failures" -ge 10 ]]; then
          exit 1
        fi
      fi
      i=$((i + 1))
      sleep 0.25
    done
  ) >"$MAC_RECORD_LOG" 2>&1 &
  MAC_RECORDER_PID="$!"
  for _ in $(seq 1 40); do
    if [[ "$(find "$MAC_FRAME_DIR" -name 'frame-*.png' -type f | wc -l | tr -d ' ')" -ge 2 ]]; then
      return 0
    fi
    if ! kill -0 "$MAC_RECORDER_PID" >/dev/null 2>&1; then
      tail -80 "$MAC_RECORD_LOG" >&2 || true
      return 1
    fi
    sleep 0.25
  done
  stop_pid_bounded "$MAC_RECORDER_PID" TERM
  MAC_RECORDER_PID=""
  tail -80 "$MAC_RECORD_LOG" >&2 || true
  return 1
}

start_ios_recording() {
  xcrun simctl io "$SIMULATOR_ID" recordVideo --codec=h264 --force "$IOS_RAW_VIDEO" 2>"$IOS_RECORD_LOG" &
  IOS_RECORDER_PID="$!"
  for _ in $(seq 1 80); do
    grep -q "Recording started" "$IOS_RECORD_LOG" 2>/dev/null && return 0
    sleep 0.25
  done
  stop_pid_bounded "$IOS_RECORDER_PID" TERM
  IOS_RECORDER_PID=""
  tail -80 "$IOS_RECORD_LOG" >&2 || true
  return 1
}

start_ios_log_capture() {
  rm -f "$IOS_SIMULATOR_LOG"
  xcrun simctl spawn "$SIMULATOR_ID" log stream \
    --style compact \
    --level debug \
    --predicate 'process == "cmux" OR subsystem == "ai.manaflow.cmux"' \
    >"$IOS_SIMULATOR_LOG" 2>&1 &
  IOS_LOG_PID="$!"
  sleep 1
}

stop_recorders() {
  stop_pid_bounded "$IOS_RECORDER_PID" INT
  IOS_RECORDER_PID=""
  stop_pid_bounded "$MAC_RECORDER_PID" INT
  MAC_RECORDER_PID=""
  stop_pid_bounded "$IOS_LOG_PID" INT
  IOS_LOG_PID=""
  local frame_count
  frame_count="$(find "$MAC_FRAME_DIR" -name 'frame-*.png' -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$frame_count" -ge 2 && ! -s "$MAC_RAW_VIDEO" ]]; then
    ffmpeg -hide_banner -y -framerate 4 -pattern_type glob -i "$MAC_FRAME_DIR/frame-*.png" \
      -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
      -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$MAC_RAW_VIDEO" >>"$MAC_RECORD_LOG" 2>&1
  fi
}

stitch_videos() {
  ffmpeg -hide_banner -y \
    -i "$MAC_RAW_VIDEO" \
    -i "$IOS_RAW_VIDEO" \
    -filter_complex "\
[0:v]trim=duration=24,setpts=PTS-STARTPTS,scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:color=0x101418,fps=30[mac];\
[1:v]trim=duration=24,setpts=PTS-STARTPTS,scale=540:960:force_original_aspect_ratio=decrease,pad=540:960:(ow-iw)/2:(oh-ih)/2:color=0x101418,fps=30[ios];\
color=c=0x0b0f14:s=1920x1080:r=30:d=24[bg];\
[bg][mac]overlay=x=40:y=(H-h)/2[tmp];\
[tmp][ios]overlay=x=W-w-40:y=(H-h)/2[out]" \
    -map "[out]" -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$FINAL_VIDEO"
  [[ -s "$FINAL_VIDEO" ]]
}

phase "checking ffmpeg"
require_ffmpeg

ios_ready() { xcrun simctl runtime list 2>/dev/null | grep -qiE "iOS [0-9].*\(Ready\)"; }
if ! ios_ready; then
  phase "installing iOS simulator platform"
  xcodebuild -downloadPlatform iOS 2>&1 | tr '\r' '\n' | grep -ivE 'Preparing to download|registering download' | tail -8 || true
  ios_ready || { echo "iOS platform is not registered" >&2; exit 1; }
fi

phase "selecting simulator"
eval "$(select_simulator)"
export SIMULATOR_ID SIMULATOR_NAME SIMULATOR_CREATED
phase "booting simulator $SIMULATOR_NAME ($SIMULATOR_ID)"
xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
xcrun simctl erase "$SIMULATOR_ID"
xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
run_with_timeout 120 xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcrun simctl ui "$SIMULATOR_ID" appearance dark || true

phase "enabling macOS mobile pairing host"
defaults write "$MAC_BUNDLE_ID" mobile.iOSPairingHost.enabled -bool true
./scripts/download-prebuilt-ghosttykit.sh || ./scripts/ensure-ghosttykit.sh

MAC_RELOAD_LOG="$ARTIFACT_DIR/reload-macos.log"
phase "building tagged macOS cmux"
run_with_timeout 600 bash -c './scripts/reload.sh --tag "$1" --swift-frontend-workaround 2>&1 | tee "$2"' bash "$BUILD_TAG" "$MAC_RELOAD_LOG"
MAC_APP_PATH="$(awk '/^App path:/{getline; sub(/^  /,""); print; exit}' "$MAC_RELOAD_LOG")"
[[ -n "$MAC_APP_PATH" && -d "$MAC_APP_PATH" ]] || { echo "could not locate built macOS app from $MAC_RELOAD_LOG" >&2; exit 1; }

phase "launching tagged macOS cmux"
run_with_timeout 30 open "$MAC_APP_PATH"
wait_for_socket

phase "activating tagged macOS cmux"
run_with_timeout 15 osascript -e "tell application id \"$MAC_BUNDLE_ID\" to activate" >/dev/null 2>&1 || true

phase "creating real cmux terminal workspace"
WORKSPACE_OUTPUT="$ARTIFACT_DIR/workspace-create-output.txt"
cmux_tagged --id-format uuids workspace create --name "iOS sync demo" --cwd "$PWD" --focus true --json > "$WORKSPACE_OUTPUT"
WORKSPACE_JSON="$(cat "$WORKSPACE_OUTPUT")"
WORKSPACE_ID="$(printf '%s\n' "$WORKSPACE_JSON" | json_field workspace_id)"
SURFACE_ID="$(printf '%s\n' "$WORKSPACE_JSON" | json_field surface_id)"

phase "configuring debug mobile Stack auth token"
DEV_STACK_AUTH_PARAMS="$(python3 - "$DEV_STACK_AUTH_TOKEN" <<'PY'
import json
import sys

print(json.dumps({"token": sys.argv[1]}, separators=(",", ":")))
PY
)"
cmux_tagged rpc mobile.dev_stack_auth.configure "$DEV_STACK_AUTH_PARAMS" >/dev/null

for _ in $(seq 1 40); do
  if cmux_tagged read-screen --workspace "$WORKSPACE_ID" --surface "$SURFACE_ID" --lines 5 >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

phase "minting terminal-scoped attach URL"
ATTACH_URL="$(mint_attach_url "$WORKSPACE_ID" "$SURFACE_ID")"
[[ -n "$ATTACH_URL" ]] || { echo "Failed to mint attach URL" >&2; exit 1; }

phase "building and installing real iOS app"
run_with_timeout 600 ios/scripts/reload.sh --tag "$BUILD_TAG" --simulator "$SIMULATOR_NAME" --no-launch
phase "seeding iOS attach launch defaults"
IOS_DATA_CONTAINER="$(run_with_timeout 30 xcrun simctl get_app_container "$SIMULATOR_ID" "$IOS_BUNDLE_ID" data)"
IOS_PREFS_PLIST="$IOS_DATA_CONTAINER/Library/Preferences/${IOS_BUNDLE_ID}.plist"
mkdir -p "$(dirname "$IOS_PREFS_PLIST")"
python3 - "$IOS_PREFS_PLIST" "$ATTACH_URL" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
attach_url = sys.argv[2]
data = {}
if path.exists():
    with path.open("rb") as handle:
        data = plistlib.load(handle)
data["CMUX_DOGFOOD_ATTACH_URL"] = attach_url
with path.open("wb") as handle:
    plistlib.dump(data, handle)
PY
run_with_timeout 30 xcrun simctl spawn "$SIMULATOR_ID" defaults write "$IOS_BUNDLE_ID" CMUX_DOGFOOD_ATTACH_URL "$ATTACH_URL"
run_with_timeout 30 xcrun simctl spawn "$SIMULATOR_ID" launchctl setenv CMUX_DOGFOOD_ATTACH_URL "$ATTACH_URL"
python3 - "$IOS_PREFS_PLIST" "$IOS_SEEDED_DEFAULTS" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
out = Path(sys.argv[2])
has_attach_url = False
attach_url_length = 0
if path.exists():
    with path.open("rb") as handle:
        data = plistlib.load(handle)
    value = data.get("CMUX_DOGFOOD_ATTACH_URL")
    has_attach_url = isinstance(value, str) and bool(value.strip())
    attach_url_length = len(value) if isinstance(value, str) else 0
out.write_text(f"hasAttachURL={str(has_attach_url).lower()}\nattachURLLength={attach_url_length}\n")
PY
start_ios_log_capture
phase "launching and auto-attaching real iOS app"
run_with_timeout 30 env \
  SIMCTL_CHILD_CMUX_UITEST_MOCK_DATA=0 \
  SIMCTL_CHILD_CMUX_UITEST_AUTH_FIXTURE=1 \
  SIMCTL_CHILD_CMUX_UITEST_AUTH_USER_ID=cloud-recording-user \
  SIMCTL_CHILD_CMUX_UITEST_AUTH_EMAIL=cloud-recording@cmux.local \
  "SIMCTL_CHILD_CMUX_UITEST_AUTH_NAME=Cloud Recording" \
  "SIMCTL_CHILD_CMUX_MOBILE_DEV_STACK_AUTH_TOKEN=$DEV_STACK_AUTH_TOKEN" \
  "SIMCTL_CHILD_CMUX_DOGFOOD_ATTACH_URL=$ATTACH_URL" \
  xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" "$IOS_BUNDLE_ID" \
    --cmux-dogfood-attach-url "$ATTACH_URL"
sleep 18

phase "starting macOS and iOS recordings"
start_macos_recording
start_ios_recording

phase "sending synced terminal input through real macOS cmux"
cmux_tagged send --workspace "$WORKSPACE_ID" --surface "$SURFACE_ID" -- "clear\r"
sleep 1
cmux_tagged send --workspace "$WORKSPACE_ID" --surface "$SURFACE_ID" -- "echo real cmux desktop to iOS\r"
sleep 1
cmux_tagged send --workspace "$WORKSPACE_ID" --surface "$SURFACE_ID" -- "echo ${SYNC_MARKER}\r"
sleep 4
cmux_tagged send --workspace "$WORKSPACE_ID" --surface "$SURFACE_ID" -- "echo same terminal, two clients\r"
sleep 6

cmux_tagged read-screen --workspace "$WORKSPACE_ID" --surface "$SURFACE_ID" --lines 20 > "$ARTIFACT_DIR/macos-read-screen.txt" || true
xcrun simctl io "$SIMULATOR_ID" screenshot --type=png "$ARTIFACT_DIR/ios-final.png" || true
find "$MAC_FRAME_DIR" -name 'frame-*.png' -type f | sort | tail -1 | while read -r frame; do
  cp "$frame" "$ARTIFACT_DIR/macos-final.png"
done

phase "stopping recorders"
stop_recorders

[[ -s "$MAC_RAW_VIDEO" ]] || { echo "macOS recording missing: $MAC_RAW_VIDEO" >&2; exit 1; }
[[ -s "$IOS_RAW_VIDEO" ]] || { echo "iOS recording missing: $IOS_RAW_VIDEO" >&2; exit 1; }
phase "stitching left-right video"
stitch_videos

phase "writing metadata"
python3 - "$METADATA_PATH" <<PY
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps({
    "tag": "$BUILD_TAG",
    "platform": "sync-video",
    "mode": "real-cmux-desktop-ios",
    "deviceFamily": "$DEVICE_FAMILY",
    "simulatorId": "$SIMULATOR_ID",
    "simulatorName": "$SIMULATOR_NAME",
    "workspaceId": "$WORKSPACE_ID",
    "surfaceId": "$SURFACE_ID",
    "syncMarker": "$SYNC_MARKER",
    "usesDebugMobileStackAuthToken": True,
    "video": "$(basename "$FINAL_VIDEO")",
    "macVideo": "$(basename "$MAC_RAW_VIDEO")",
    "iosVideo": "$(basename "$IOS_RAW_VIDEO")",
}, indent=2) + "\n")
PY

echo "Real cmux desktop+iOS video: $FINAL_VIDEO"
