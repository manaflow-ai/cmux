#!/usr/bin/env bash
# NEVER MERGE (SWITCH FRAMES SF-2): the app footprint of one warm hidden terminal on a 2x virtual display at a given
# window size, to size WarmSetBudget.terminalCostBytes from a measurement (scripts/cmux-next/warm_set_cost.py).
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/warm-set-cost.sh \
#     --ref SHA --artifact artifacts/warm-set-cost/report.json [--arg=--scale=2] [--arg=--points=1512x982]
#     [--arg=--window=full|WxH] [--arg=--counts=1,2,...]
# --points: the virtual display's size in points (2x: backed by twice the pixels; 1512x982 is a 14-inch MacBook Pro's
# default). --window: `full` fills the display's visible frame (a zoomed window), WxH centres a window of that size.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
scale=2 points=1512x982 window=full counts="1,2,4,6,8,10,12,16,20,24,32" hold=3000
for arg in "$@"; do
  case "$arg" in
    --scale=*) scale="${arg#--scale=}" ;;
    --points=*) points="${arg#--points=}" ;;
    --window=*) window="${arg#--window=}" ;;
    --counts=*) counts="${arg#--counts=}" ;;
    *) echo "warm-set-cost.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
out="$(pwd)/artifacts/warm-set-cost"
mkdir -p "$out"
echo "WARMCOST-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion)"
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub"
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag warmcost --config bench 2>&1 | tee "$out/reload.log" > /dev/null || { tail -n 80 "$out/reload.log"; exit 1; }
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
[[ -n "$app" && -d "$app" ]] || { echo "warm-set-cost: reload printed no app path" >&2; tail -n 40 "$out/reload.log"; exit 1; }

vd="$out/vdisplay"
mkdir -p "$vd/VDisplay.app/Contents/MacOS"
xcrun clang -fobjc-arc -O2 -Wno-deprecated-declarations -framework AppKit -framework CoreVideo \
  scripts/ci/frame-pacing/vdisplay.m -o "$vd/VDisplay.app/Contents/MacOS/VDisplay"
cp scripts/ci/frame-pacing/VDisplay-Info.plist "$vd/VDisplay.app/Contents/Info.plist"
codesign -s - --force "$vd/VDisplay.app" 2>/dev/null || true
"$vd/VDisplay.app/Contents/MacOS/VDisplay" 60 "$hold" main "$points" "$scale" > "$vd/out" 2> "$vd/err" &
vdisplay_pid=$!
trap 'kill "$vdisplay_pid" 2>/dev/null || true' EXIT
for _ in $(seq 25); do
  grep -q '^ready\|^error' "$vd/out" 2>/dev/null && break
  sleep 1  # bounded wait for the helper's own ready line
done
line="$(grep -m1 '^ready\|^error' "$vd/out" 2>/dev/null || echo "error: no ready line ($(head -c 300 "$vd/err"))")"
echo "WARMCOST-DISPLAY $line"
# ready ID MS main=MAIN size=WxH visible=WxH scale=S visible_origin=XxY
read -r display_json frame < <(python3 - "$line" "$window" "$scale" <<'PY'
import json, re, sys
line, window, want = sys.argv[1], sys.argv[2], int(sys.argv[3])
m = re.match(r"ready (\d+) ([\d.]+) main=(\d+) size=(\d+)x(\d+) visible=(\d+)x(\d+) scale=(\d+) visible_origin=(-?\d+)x(-?\d+)", line)
if not m or m.group(1) != m.group(3) or int(m.group(8)) != want:
    print(json.dumps({"error": line}).replace(" ", ""), "none"); sys.exit()
vw, vh, ox, oy = int(m.group(6)), int(m.group(7)), int(m.group(9)), int(m.group(10))
# CMUX_NEXT_TEST_WINDOW_FRAME is inside the screen's visible frame, from its top-left corner (TestWindowPlacement).
if window == "full":
    w, h, x, y = vw, vh, 0, 0
else:
    w, h = (int(v) for v in window.split("x"))
    x, y = (vw - w) // 2, (vh - h) // 2
d = {"display_id": int(m.group(1)), "refresh_ms": float(m.group(2)), "points": [int(m.group(4)), int(m.group(5))],
     "scale": int(m.group(8)), "pixels": [int(m.group(4)) * int(m.group(8)), int(m.group(5)) * int(m.group(8))],
     "visible": [vw, vh], "asked_window": window}
print(json.dumps(d).replace(" ", ""), f"{x},{y},{w},{h}")
PY
)
if [[ "$frame" == none ]]; then
  echo "warm-set-cost: NOT RUN: the ${scale}x virtual display did not come up as the main display ($line)" >&2
  exit 1
fi
sleep 2  # let WindowServer settle the new main display before the app opens on it
echo "WARMCOST-WINDOW $frame display=$display_json"
CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/warm_set_cost.py --app "$app" --window "$frame" \
  --display "$display_json" --counts "$counts" --out "$out/report.json"
