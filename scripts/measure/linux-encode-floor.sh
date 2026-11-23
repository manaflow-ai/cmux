#!/usr/bin/env bash
# Linux host encode against its floor (goal screen-share-linux-pairs, cmuxterm-hq goals/screen-share-linux-pairs.md).
# The shipped OpenH264 settings code codec-bench's scenes (page, scroll, drag, typing; 1080p30); x264, the fastest
# software H.264 (ultrafast, zerolatency, one-frame VBV), codes the very same frames, written out by `scene-dump`.
# Both run pinned to the same CORES cores. Prints one JSON line:
#   {"schema":"linux-encode-floor.v1","worst_ratio":R,"scenes":{SCENE:{"shipped_p50_ms":..,"floor_mean_ms":..,"ratio":..}},...}
# worst_ratio is the goal's number: within 2x means worst_ratio <= 2.
# Needs on Linux: rustup's cargo, nasm (OpenH264's assembly; without it the shipped row reads slow), x264, taskset.
#   scripts/measure/linux-encode-floor.sh [--cores 4] [--out DIR]
set -euo pipefail
cores=4 out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cores) cores="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Linux ]] || { echo "linux-encode-floor runs on Linux only" >&2; exit 2; }
for tool in cargo nasm x264 taskset python3; do
  command -v "$tool" >/dev/null || { echo "linux-encode-floor: $tool is not installed" >&2; exit 2; }
done
(( $(nproc) >= cores )) || { echo "linux-encode-floor: $cores cores asked, $(nproc) present" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
out="${out:-$root/artifacts/linux-encode-floor}"
mkdir -p "$out"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$root/.build/linux-encode-floor-target}"
(cd "$root/cmux-tui/crates/cmux-codecs" &&
  cargo build --locked --release --no-default-features --bin codec-bench --bin scene-dump 2>&1 |
  grep -v -E '^ *(Compiling|Downloaded|Downloading)' | tail -5) >&2
bin="$CARGO_TARGET_DIR/release"
last=$((cores - 1))
scenes=(page scroll drag typing)
echo "linux-encode-floor: $(sed -n 's/^model name\s*: //p' /proc/cpuinfo | head -1), $cores of $(nproc) cores, load $(cut -d' ' -f1-3 /proc/loadavg)" >&2
taskset -c "0-$last" "$bin/codec-bench" --codecs h264 --scenes "$(IFS=,; echo "${scenes[*]}")" --loss 0 \
  --seconds 10 --threads "$cores" --json "$out/shipped.jsonl" >&2
for s in "${scenes[@]}"; do
  "$bin/scene-dump" "$s" 300 "$out/$s.yuv"
  taskset -c "0-$last" x264 --input-res 1920x1080 --input-csp i420 --fps 30 --demuxer raw --preset ultrafast \
    --tune zerolatency --threads "$cores" --sliced-threads --profile baseline --bitrate 8000 --vbv-maxrate 8000 \
    --vbv-bufsize 267 --keyint infinite -o /dev/null "$out/$s.yuv" 2>&1 | grep -E '^encoded' > "$out/$s.x264.txt"
  rm -f "$out/$s.yuv"
done
python3 -I - "$out" "$cores" <<'PY'
import json, re, sys
out, cores = sys.argv[1], int(sys.argv[2])
shipped = {}
for line in open(f"{out}/shipped.jsonl"):
    row = json.loads(line)
    shipped[row["scene"]] = row["encode_ms"]["p50"]
scenes = {}
for scene, p50 in shipped.items():
    text = open(f"{out}/{scene}.x264.txt").read()
    fps = float(re.search(r"([0-9.]+) fps", text).group(1))
    floor = 1000.0 / fps
    scenes[scene] = {"shipped_p50_ms": round(p50, 2), "floor_mean_ms": round(floor, 2), "ratio": round(p50 / floor, 2)}
result = {"schema": "linux-encode-floor.v1", "cores": cores,
          "worst_ratio": max(s["ratio"] for s in scenes.values()), "scenes": scenes}
json.dump(result, open(f"{out}/result.json", "w"))
print(json.dumps(result))
PY
