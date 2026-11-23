#!/usr/bin/env bash
# Camera usage on spare bitrate (ledger idea w47-28, goal screen-share-linux-pairs cut 1) against shipped.
# Codes codec-bench's scenes (page, scroll, drag, typing; 1080p30, 10 s, 0% loss) with the shipped OpenH264
# usage (`switch`), the opt-in `usage=spare` and all-camera `usage=camera`, on the bench's 30 Mbps link (a LAN
# or wired pair: 41.9 Mbps measured Linux to Mac). x264 ultrafast codes the same frames for the floor, as
# scripts/measure/linux-encode-floor.sh does. Every run is pinned to CORES cores. The fallback below
# SPARE_KBPS is a unit test (openh264.rs spare_usage_follows_the_target_bitrate): on a bench link of 15 Mbps or
# less the page scene shows under 3 fps with every usage, shipped included, so it measures nothing here.
# Prints one JSON line with each usage's worst_ratio and a row per usage and scene:
#   {"schema":"linux-encode-spare.v1","worst_ratio":{"switch":R,"spare":R,"camera":R},"rows":[...]}
#   scripts/measure/linux-encode-spare.sh [--cores 4] [--out DIR]
set -euo pipefail
cores=4 out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cores) cores="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Linux ]] || { echo "linux-encode-spare runs on Linux only" >&2; exit 2; }
for tool in cargo nasm x264 taskset python3; do
  command -v "$tool" >/dev/null || { echo "linux-encode-spare: $tool is not installed" >&2; exit 2; }
done
root="$(git rev-parse --show-toplevel)"
out="${out:-$root/artifacts/linux-encode-spare}"
mkdir -p "$out"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$root/.build/linux-encode-floor-target}"
(cd "$root/cmux-tui/crates/cmux-codecs" &&
  cargo build --locked --release --no-default-features --bin codec-bench --bin scene-dump 2>&1 |
  grep -v -E '^ *(Compiling|Downloaded|Downloading)' | tail -5) >&2
bin="$CARGO_TARGET_DIR/release"
last=$((cores - 1))
scenes=(page scroll drag typing)
usages=(switch spare camera)
echo "linux-encode-spare: $(sed -n 's/^model name\s*: //p' /proc/cpuinfo | head -1), $cores of $(nproc) cores, load $(cut -d' ' -f1-3 /proc/loadavg)" >&2
: > "$out/rows.jsonl"
# Scene by scene, every usage back to back, so load drift on the host lands on all columns alike.
for s in "${scenes[@]}"; do
  for u in "${usages[@]}"; do
    CMUX_OPENH264_TUNING="usage=$u" taskset -c "0-$last" "$bin/codec-bench" --codecs h264 --scenes "$s" --loss 0 \
      --seconds 10 --threads "$cores" --link-mbps 30 --json "$out/row.json" >&2
    python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); r["usage"]=sys.argv[2]; print(json.dumps(r))' \
      "$out/row.json" "$u" >> "$out/rows.jsonl"
  done
  "$bin/scene-dump" "$s" 300 "$out/$s.yuv"
  taskset -c "0-$last" x264 --input-res 1920x1080 --input-csp i420 --fps 30 --demuxer raw --preset ultrafast \
    --tune zerolatency --threads "$cores" --sliced-threads --profile baseline --bitrate 8000 --vbv-maxrate 8000 \
    --vbv-bufsize 267 --keyint infinite -o /dev/null "$out/$s.yuv" 2>&1 | grep -E '^encoded' > "$out/$s.x264.txt"
  rm -f "$out/$s.yuv"
done
rm -f "$out/row.json"
python3 -I - "$out" "$cores" <<'PY'
import json, re, sys
rnd = lambda x, n=2: None if x is None else round(x, n)
out, cores = sys.argv[1], int(sys.argv[2])
floor = {}
rows = [json.loads(l) for l in open(f"{out}/rows.jsonl")]
for r in rows:
    s = r["scene"]
    if s not in floor:
        fps = float(re.search(r"([0-9.]+) fps", open(f"{out}/{s}.x264.txt").read()).group(1))
        floor[s] = 1000.0 / fps
table, worst = [], {}
for r in rows:
    p50 = r["encode_ms"]["p50"]
    ratio = p50 / floor[r["scene"]]
    table.append({"usage": r["usage"], "scene": r["scene"],
                  "encode_p50_ms": round(p50, 2), "floor_mean_ms": round(floor[r["scene"]], 2),
                  "ratio": round(ratio, 2), "media_mbps": round(r["media_mbps"], 2),
                  "psnr_y_db": rnd(r["psnr_y_db"]["mean"]),
                  "screen_psnr_y_db": rnd(r["screen_psnr_y_db"]["mean"]),
                  "screen_psnr_p5_db": rnd(r["screen_psnr_y_db"]["p5"]),
                  "shown_fps": round(r["shown_fps"], 1), "keyframes": r["keyframes"],
                  "final_target_kbps": r["final_target_kbps"], "encoder": r["encoder"]})
    worst[r["usage"]] = max(worst.get(r["usage"], 0), round(ratio, 2))
result = {"schema": "linux-encode-spare.v1", "cores": cores, "worst_ratio": worst, "rows": table}
json.dump(result, open(f"{out}/result.json", "w"))
print(json.dumps(result))
PY
