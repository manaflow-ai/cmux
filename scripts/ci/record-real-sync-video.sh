#!/usr/bin/env bash
set -euo pipefail

BUILD_TAG="${BUILD_TAG:?BUILD_TAG is required}"
DEVICE_FAMILY="${DEVICE_FAMILY:-iphone}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$PWD/artifact}"
SYNC_MARKER="${SYNC_MARKER:-cmux-real-sync-video}"

mkdir -p "$ARTIFACT_DIR"

phase() {
  echo "==> $*"
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
IOS_RECORD_LOG="$ARTIFACT_DIR/ios-record.log"
METADATA_PATH="$ARTIFACT_DIR/metadata.json"

MAC_RECORDER_PID=""
IOS_RECORDER_PID=""
SIMULATOR_ID=""
SIMULATOR_CREATED="0"

cleanup() {
  set +e
  if [[ -n "$MAC_RECORDER_PID" ]] && kill -0 "$MAC_RECORDER_PID" >/dev/null 2>&1; then
    kill -INT "$MAC_RECORDER_PID" >/dev/null 2>&1 || true
    wait "$MAC_RECORDER_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$IOS_RECORDER_PID" ]] && kill -0 "$IOS_RECORDER_PID" >/dev/null 2>&1; then
    kill -INT "$IOS_RECORDER_PID" >/dev/null 2>&1 || true
    wait "$IOS_RECORDER_PID" >/dev/null 2>&1 || true
  fi
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
  CMUX_TAG="$BUILD_TAG" scripts/cmux-debug-cli.sh "$@"
}

json_field() {
  python3 - "$1" <<'PY'
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
PY
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
  local devlist
  local screen_index
  devlist="$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 || true)"
  echo "$devlist" | grep -E "AVFoundation|Capture screen" || true
  screen_index="$(echo "$devlist" | grep "Capture screen" | head -1 | sed 's/.*\[\([0-9]*\)\].*/\1/')"
  screen_index="${screen_index:-0}"
  ffmpeg -hide_banner -y -f avfoundation -framerate 15 -capture_cursor 1 \
    -i "${screen_index}:none" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
    "$MAC_RAW_VIDEO" </dev/null >"$MAC_RECORD_LOG" 2>&1 &
  MAC_RECORDER_PID="$!"
  sleep 2
  kill -0 "$MAC_RECORDER_PID" >/dev/null 2>&1
}

start_ios_recording() {
  xcrun simctl io "$SIMULATOR_ID" recordVideo --codec=h264 --force "$IOS_RAW_VIDEO" 2>"$IOS_RECORD_LOG" &
  IOS_RECORDER_PID="$!"
  for _ in $(seq 1 80); do
    grep -q "Recording started" "$IOS_RECORD_LOG" 2>/dev/null && return 0
    sleep 0.25
  done
  cat "$IOS_RECORD_LOG" >&2 || true
  return 1
}

stop_recorders() {
  if [[ -n "$IOS_RECORDER_PID" ]] && kill -0 "$IOS_RECORDER_PID" >/dev/null 2>&1; then
    kill -INT "$IOS_RECORDER_PID" >/dev/null 2>&1 || true
    wait "$IOS_RECORDER_PID" >/dev/null 2>&1 || true
  fi
  IOS_RECORDER_PID=""
  if [[ -n "$MAC_RECORDER_PID" ]] && kill -0 "$MAC_RECORDER_PID" >/dev/null 2>&1; then
    kill -INT "$MAC_RECORDER_PID" >/dev/null 2>&1 || true
    wait "$MAC_RECORDER_PID" >/dev/null 2>&1 || true
  fi
  MAC_RECORDER_PID=""
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
timeout 120s xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcrun simctl ui "$SIMULATOR_ID" appearance dark || true

phase "enabling macOS mobile pairing host"
defaults write "$MAC_BUNDLE_ID" mobile.iOSPairingHost.enabled -bool true
./scripts/download-prebuilt-ghosttykit.sh || ./scripts/ensure-ghosttykit.sh

MAC_RELOAD_LOG="$ARTIFACT_DIR/reload-macos.log"
phase "building and launching tagged macOS cmux"
timeout 600s ./scripts/reload.sh --tag "$BUILD_TAG" --swift-frontend-workaround --launch 2>&1 | tee "$MAC_RELOAD_LOG"
wait_for_socket

phase "activating tagged macOS cmux"
timeout 15s osascript <<OSA >/dev/null 2>&1 || true
tell application id "$MAC_BUNDLE_ID" to activate
OSA

phase "creating real cmux terminal workspace"
WORKSPACE_JSON="$(cmux_tagged --json --id-format uuids new-workspace --name "iOS sync demo" --cwd "$PWD" --focus true)"
WORKSPACE_ID="$(printf '%s\n' "$WORKSPACE_JSON" | json_field workspace_id)"
SURFACE_ID="$(printf '%s\n' "$WORKSPACE_JSON" | json_field surface_id)"

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
timeout 600s ios/scripts/reload.sh --tag "$BUILD_TAG" --simulator "$SIMULATOR_NAME" --no-launch
phase "launching and attaching real iOS app"
xcrun simctl terminate "$SIMULATOR_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl launch "$SIMULATOR_ID" "$IOS_BUNDLE_ID" >/dev/null
sleep 2
timeout 30s xcrun simctl openurl "$SIMULATOR_ID" "$ATTACH_URL"
sleep 5

phase "starting macOS and iOS recordings"
start_macos_recording
start_ios_recording

phase "sending synced terminal input through real macOS cmux"
cmux_tagged send --workspace "$WORKSPACE_ID" --surface "$SURFACE_ID" -- "clear\r"
sleep 1
cmux_tagged send --workspace "$WORKSPACE_ID" --surface "$SURFACE_ID" -- "printf 'real cmux desktop <> iOS\\n'\r"
sleep 1
cmux_tagged send --workspace "$WORKSPACE_ID" --surface "$SURFACE_ID" -- "echo ${SYNC_MARKER}\r"
sleep 4
cmux_tagged send --workspace "$WORKSPACE_ID" --surface "$SURFACE_ID" -- "printf 'same terminal, two clients\\n'\r"
sleep 6

cmux_tagged read-screen --workspace "$WORKSPACE_ID" --surface "$SURFACE_ID" --lines 20 > "$ARTIFACT_DIR/macos-read-screen.txt" || true
xcrun simctl io "$SIMULATOR_ID" screenshot --type=png "$ARTIFACT_DIR/ios-final.png" || true
screencapture -x "$ARTIFACT_DIR/macos-final.png" || true

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
    "video": "$(basename "$FINAL_VIDEO")",
    "macVideo": "$(basename "$MAC_RAW_VIDEO")",
    "iosVideo": "$(basename "$IOS_RAW_VIDEO")",
}, indent=2) + "\n")
PY

echo "Real cmux desktop+iOS video: $FINAL_VIDEO"
