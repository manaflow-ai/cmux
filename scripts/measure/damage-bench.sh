#!/usr/bin/env bash
# What encoding only the damaged region saves OpenH264 (cmuxterm-hq goal screen-share-linux-pairs; idea
# ledger w47-29). Measurement only: nothing a host links changes.
#
# damage-bench (cmux-tui/crates/cmux-codecs/src/bin/damage-bench.rs) codes a static 1080p screen with one
# rectangle of new content per frame, for rectangles 64x32, 640x32, 640x480 and the full frame, three ways:
# full (whole frame, today), crop (an encoder at the rectangle's size: a sub-picture stream's floor) and
# skip (whole frame, macroblocks outside the rectangle forced to P_Skip by cmux-tui/crates/cmux-codecs/
# openh264-damage.patch). Each runs under shipped settings and with FME off (openh264-ablation.patch's
# CMUX_OH264_ABLATE=fme), pinned to the same cores under nice, beside x264 ultrafast on the same pictures.
#
#   scripts/measure/damage-bench.sh [--cores 4] [--out DIR] [--frames 300]
set -euo pipefail
cores=4 out="" frames=300
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cores) cores="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --frames) frames="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Linux ]] || { echo "damage-bench runs on Linux only" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
out="${out:-${FAST_CHECKS_OUT:-$root/artifacts/damage-bench}}"
mkdir -p "$out"
sudo_n() { if [[ $(id -u) == 0 ]]; then "$@"; else sudo -n "$@"; fi; }
for tool in nasm x264 patch; do
  command -v "$tool" >/dev/null || sudo_n apt-get install -y -qq "$tool" >/dev/null 2>&1 ||
    echo "damage-bench: $tool not installed and could not be" >&2
done
command -v nasm >/dev/null || { echo "damage-bench: no nasm" >&2; exit 2; }
n=$(nproc)
(( n >= cores )) || cores=$n
last=$((cores - 1))
crate="$root/cmux-tui/crates/cmux-codecs"
work="$(mktemp -d)"
cd "$crate"
cargo fetch --locked >/dev/null 2>&1 || cargo fetch --locked
sys2="$(cargo metadata --locked --format-version 1 | python3 -I -c '
import json, sys
m = json.load(sys.stdin)
print(next(p["manifest_path"] for p in m["packages"] if p["name"] == "openh264-sys2").rsplit("/", 1)[0])')"
cp -r "$sys2" "$work/openh264-sys2"
chmod -R u+w "$work/openh264-sys2"
patch -s -p1 -d "$work/openh264-sys2/upstream/codec" < "$crate/openh264-ablation.patch"
patch -s -p1 -d "$work/openh264-sys2/upstream/codec" < "$crate/openh264-damage.patch"
cp Cargo.lock "$work/Cargo.lock.orig"
trap 'cp "$work/Cargo.lock.orig" "$crate/Cargo.lock"; rm -rf "$work"' EXIT
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$root/.build/damage-bench-target}"
cargo build --release --no-default-features --bin damage-bench \
  --config "patch.crates-io.openh264-sys2.path=\"$work/openh264-sys2\"" 2>&1 |
  grep -v -E '^ *(Compiling|Downloaded|Downloading|Locking|Adding|Updating)' | tail -8 >&2
cp "$work/Cargo.lock.orig" Cargo.lock
bin="$CARGO_TARGET_DIR/release/damage-bench"
machine="$(sed -n 's/^model name\s*: //p' /proc/cpuinfo | head -1), $cores of $n cores pinned"
echo "damage-bench: $machine, load $(cut -d' ' -f1-3 /proc/loadavg)" >&2

: > "$out/rows.jsonl"
mkdir -p "$work/yuv"
rects=(64x32 640x32 640x480 1920x1080)
for content in typing page; do
  for r in "${rects[@]}"; do
    for mode in full crop skip; do
      for v in "shipped|" "fme off|fme"; do
        IFS='|' read -r vname ablate <<< "$v"
        dump=()
        [[ "$vname" == shipped ]] && dump=(--dump "$work/yuv")
        CMUX_OH264_ABLATE="$ablate" nice -n 10 taskset -c "0-$last" "$bin" --rect "$r" --mode "$mode" \
          --content "$content" --frames "$frames" --threads "$cores" "${dump[@]}" --json "$work/row.jsonl" > /dev/null
        python3 -I -c '
import json, sys
name = sys.argv[1]
row = json.loads(open(sys.argv[3]).read().splitlines()[-1]); row["variant"] = name
open(sys.argv[2], "a").write(json.dumps(row) + "\n")' "$vname" "$out/rows.jsonl" "$work/row.jsonl"
      done
      echo "damage-bench: $content $r $mode done" >&2
    done
  done
done

# The floor on the same cores: x264 ultrafast/zerolatency on the very pictures the shipped rows coded.
: > "$out/x264.jsonl"
if command -v x264 >/dev/null; then
  for f in "$work"/yuv/*.yuv; do
    base="$(basename "$f" .yuv)"; r="$(sed -E 's/^[a-z]+-([0-9]+x[0-9]+)-.*/\1/' <<< "$base")"
    ms="$(nice -n 10 taskset -c "0-$last" x264 --input-res "$r" --input-csp i420 --fps 30 --demuxer raw \
      --preset ultrafast --tune zerolatency --threads "$cores" --sliced-threads --profile baseline --bitrate 8000 \
      --vbv-maxrate 8000 --vbv-bufsize 267 --keyint infinite --psnr -o /dev/null "$f" 2>&1 |
      sed -n 's/^encoded .* \([0-9.]*\) fps.*/\1/p' | head -1)"
    echo "{\"name\":\"$base\",\"fps\":${ms:-0}}" >> "$out/x264.jsonl"
  done
fi

python3 -I - "$out" "$machine" <<'PY'
import json, sys
out, machine = sys.argv[1:3]
rows = [json.loads(l) for l in open(f"{out}/rows.jsonl")]
x264 = {}
for l in open(f"{out}/x264.jsonl"):
    d = json.loads(l)
    x264[d["name"]] = 1000.0 / d["fps"] if d["fps"] else None
lines = [f"Machine: {machine}.", ""]
for content in ["typing", "page"]:
    lines += [f"{content} content", "",
              "| damage | variant | full p50 ms | crop p50 ms | skip p50 ms | x264 full / crop mean ms | full PSNR dB (rect) | crop PSNR dB (rect) | skip PSNR dB (rect) | full kbps | crop kbps | skip kbps |",
              "|---" * 12 + "|"]
    for r in ["64x32", "640x32", "640x480", "1920x1080"]:
        for v in ["shipped", "fme off"]:
            g = {x["mode"]: x for x in rows if x["content"] == content and x["rect"] == r and x["variant"] == v}
            if len(g) < 3:
                continue
            f = lambda m, k: f'{g[m][k]:.2f}' if m in g else "-"
            fl = x264.get(f"{content}-{r}-full"); cr = x264.get(f"{content}-{r}-crop")
            fx = "-" if v != "shipped" or fl is None else f"{fl:.2f} / {cr:.2f}" if cr else f"{fl:.2f}"
            ps = lambda m: f'{g[m]["psnr_full_db"]:.1f} ({g[m]["psnr_rect_db"]:.1f})'
            lines.append(f"| {r} | {v} | " + " | ".join(f(m, "encode_ms_p50") for m in ["full", "crop", "skip"]) + f" | {fx} | "
                         + " | ".join(ps(m) for m in ["full", "crop", "skip"]) + " | "
                         + " | ".join(f"{g[m]['kbps']:.0f}" for m in ["full", "crop", "skip"]) + " |")
    lines.append("")
open(f"{out}/table.md", "w").write("\n".join(lines))
print("\n".join(lines))
PY
exit 0
