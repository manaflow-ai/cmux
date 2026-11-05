#!/bin/zsh
# Interleaved comparison of the WebRTC Mac Screen engine and cmux.rd/1 on one host Mac,
# through a running mac-rig.sh, viewer on the same Mac. ROOT/wrtest holds the built
# CmuxVNCWebRTC test bundle (RdMarkerClickLatencyTests) and WebRTC.framework.
#   mac-compare.sh ROOT ROUNDS SAMPLES
# Writes ROOT/results/cmp-<round>-<row>.json.
set -u
root=$1 rounds=$2 samples=$3
state=$root/state results=$root/results
mkdir -p "$results"
helper=$(find /Applications/Xcode.app/Contents/Developer/Toolchains -name swiftpm-testing-helper | head -1)
frameworks=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks

# Starts a rig command with fresh logs, then waits (bounded) until `line` shows in `log`.
start() {
  local command=$1 flags=$2 log=$3 line=$4
  echo stop > "$root/ctl"
  rm -f "$state/host.log" "$state/marker.log" "$state/webrtc.log"
  if [[ -n $flags ]]; then print -r -- "$flags" > "$state/host-flags"; else rm -f "$state/host-flags"; fi
  echo "$command" > "$root/ctl"
  for _ in {1..100}; do
    grep -q "$line" "$log" 2>/dev/null && grep -q click-at "$state/marker.log" 2>/dev/null && break
    sleep 0.1 # bounded wait for the host's ready line (10 s)
  done
  rm -f "$state/host-flags"
}

rd_row() {
  local name=$1 command=$2 flags=$3
  start "$command" "$flags --loopback 1" "$state/host.log" listening
  local geometry=$(grep -m1 marker-origin "$state/marker.log")
  local origin=${${geometry#marker-origin }%% *} at=${geometry##*click-at }
  "$root/bin/cmux-rd-bench" bench --addr 127.0.0.1:4103 --input click --at "$at" --marker-origin "$origin" \
    --samples "$samples" --user owner --token-fd 3 3< <(cat "$state/token") 2>/dev/null | tail -1 > "$results/$name.json"
}

webrtc_row() {
  local name=$1 command=$2
  start "$command" "" "$state/webrtc.log" "waiting for a viewer"
  # The marker reports its geometry in the rd stream's pixels at the display's full width.
  local geometry=$(grep -m1 "stream width" "$state/marker.log")
  local width=${${geometry#*stream width }%% *}
  local origin=$(grep -m1 marker-origin "$state/marker.log")
  local top=${${origin#marker-origin 0,}%% *}
  # "display (W, H)" in points: the stream keeps the display's aspect.
  local display=${${geometry#*display \(}%\)*}
  local height=$(python3 -c "import sys; w=float(sys.argv[1]); dw, dh = map(float, sys.argv[2].split(',')); print(int(w * dh / dw) & ~1)" "$width" "$display")
  (cd "$root/wrtest" && CMUX_VNC_STREAM_LINK=$(grep -m1 -o 'cmux-vnc://pair[^ ]*' "$state/webrtc.log") \
    CMUX_RD_MARKER_CELL_FRACTION=$(python3 -c "import sys; print(32/float(sys.argv[1]))" "$width") \
    CMUX_RD_MARKER_ORIGIN_Y=$(python3 -c "import sys; print(int(sys.argv[1])/int(sys.argv[2]))" "$top" "$height") \
    CMUX_RD_MARKER_SAMPLES=$samples DYLD_FRAMEWORK_PATH=$frameworks:$PWD \
    DYLD_LIBRARY_PATH=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib \
    "$helper" --test-bundle-path "$PWD/CmuxVNCWebRTCPackageTests.xctest/Contents/MacOS/CmuxVNCWebRTCPackageTests" \
    --testing-library swift-testing --filter RdMarkerClickLatencyTests 2>&1) \
    | sed -n 's/^rdmarker: //p' > "$results/$name.json"
}

for round in $(seq 1 "$rounds"); do
  webrtc_row "cmp-$round-webrtc-idle" webrtc
  rd_row "cmp-$round-rd-native60-idle" rd "--max-fps 60"
  rd_row "cmp-$round-rd-2560x120-idle" rd "--max-width 2560 --max-fps 120"
  webrtc_row "cmp-$round-webrtc-motion" webrtc-motion
  rd_row "cmp-$round-rd-native60-motion" rd-motion "--max-fps 60"
  rd_row "cmp-$round-rd-2560x120-motion" rd-motion "--max-width 2560 --max-fps 120"
  echo "round $round done"
done
echo stop > "$root/ctl"
