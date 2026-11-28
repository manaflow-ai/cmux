#!/usr/bin/env bash
# Which OpenH264 screen-content tool costs screen usage its ~3x encode time (cmuxterm-hq goal
# screen-share-linux-pairs, "## Ceiling"; idea ledger w47-31). Measurement only: nothing a host links changes.
#
# codec-bench is built against a patched OpenH264 (cmux-tui/crates/cmux-codecs/openh264-ablation.patch, applied
# to a copy of the openh264-sys2 crate through cargo's [patch], never committed into the lock): CMUX_OH264_ABLATE
# turns screen-content tools off one at a time (the patch's cmux_ablate.h lists them). Every variant codes the
# scenes page, scroll, drag, typing at 1080p30 for 10 s, 0% loss, pinned to the same CORES cores, under nice.
# x264 ultrafast/zerolatency codes the very same frames (scene-dump) for the floor when x264 is installed.
#
#   scripts/measure/openh264-ablation.sh [--cores 4] [--out DIR] [--variants NAME,NAME]
#
# Writes OUT/rows.jsonl (codec-bench rows, each with "variant"), OUT/table.md and OUT/floor.json; a perf profile
# of screen and camera usage on the scroll scene (OUT/perf-*.txt) when perf works here.
set -euo pipefail
cores=4 out="" only=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cores) cores="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --variants) only="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Linux ]] || { echo "openh264-ablation runs on Linux only" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
out="${out:-${FAST_CHECKS_OUT:-$root/artifacts/openh264-ablation}}"
mkdir -p "$out"
sudo_n() { if [[ $(id -u) == 0 ]]; then "$@"; else sudo -n "$@"; fi; }
for tool in nasm x264 patch; do
  command -v "$tool" >/dev/null || sudo_n apt-get install -y -qq "$tool" >/dev/null 2>&1 ||
    echo "openh264-ablation: $tool not installed and could not be" >&2
done
command -v nasm >/dev/null || { echo "openh264-ablation: no nasm: OpenH264 would build without its assembly" >&2; exit 2; }
command -v patch >/dev/null || { echo "openh264-ablation: no patch" >&2; exit 2; }
n=$(nproc)
(( n >= cores )) || { echo "openh264-ablation: $cores cores asked, $n present; using $n" >&2; cores=$n; }
last=$((cores - 1))

crate="$root/cmux-tui/crates/cmux-codecs"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$crate"
cargo fetch --locked >/dev/null 2>&1 || cargo fetch --locked
sys2="$(cargo metadata --locked --format-version 1 | python3 -I -c '
import json, sys
m = json.load(sys.stdin)
print(next(p["manifest_path"] for p in m["packages"] if p["name"] == "openh264-sys2").rsplit("/", 1)[0])')"
cp -r "$sys2" "$work/openh264-sys2"
chmod -R u+w "$work/openh264-sys2"
patch -s -p1 -d "$work/openh264-sys2/upstream/codec" < "$crate/openh264-ablation.patch"
# The [patch] rewrites Cargo.lock's openh264-sys2 entry; the checkout's lock is put back after the build.
cp Cargo.lock "$work/Cargo.lock.orig"
trap 'cp "$work/Cargo.lock.orig" "$crate/Cargo.lock"; rm -rf "$work"' EXIT
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$root/.build/openh264-ablation-target}"
cargo build --release --no-default-features --bin codec-bench --bin scene-dump \
  --config "patch.crates-io.openh264-sys2.path=\"$work/openh264-sys2\"" 2>&1 |
  grep -v -E '^ *(Compiling|Downloaded|Downloading|Locking|Adding|Updating)' | tail -8 >&2
cp "$work/Cargo.lock.orig" Cargo.lock
bin="$CARGO_TARGET_DIR/release"
asm=yes
grep -rqs "not using any assembly" "$CARGO_TARGET_DIR"/release/build/openh264-sys2-*/output && asm=no
machine="$(sed -n 's/^model name\s*: //p' /proc/cpuinfo | head -1), $cores of $n cores pinned, OpenH264 assembly: $asm"
echo "openh264-ablation: $machine, load $(cut -d' ' -f1-3 /proc/loadavg)" >&2

# name|CMUX_OPENH264_TUNING|CMUX_OH264_ABLATE
variants=(
  "shipped||"
  "screen|usage=screen|"
  "camera|usage=camera|"
  "screen -scroll|usage=screen|scroll"
  "screen -scd|usage=screen|scd"
  "screen -pskip|usage=screen|pskip"
  "screen -fme|usage=screen|fme"
  "screen -cross|usage=screen|cross"
  "screen -staticme|usage=screen|staticme"
  "screen -finemd|usage=screen|finemd"
  "screen -mvrange|usage=screen|mvrange"
  "screen -fasti|usage=screen|fasti"
  "screen qp12-51|usage=screen,minqp=12,maxqp=51|"
  "screen -scd -scroll|usage=screen|scd,scroll"
  "screen -me/md|usage=screen|fme,cross,staticme,finemd"
  "screen -all tools|usage=screen|scroll,scd,pskip,fme,cross,staticme,finemd,mvrange,fasti"
  "shipped (again)||"
  "camera (again)|usage=camera|"
)
: > "$out/rows.jsonl"
for v in "${variants[@]}"; do
  IFS='|' read -r name tuning ablate <<< "$v"
  if [[ -n "$only" && ",$only," != *",$name,"* ]]; then continue; fi
  CMUX_OPENH264_TUNING="$tuning" CMUX_OH264_ABLATE="$ablate" nice -n 10 taskset -c "0-$last" \
    "$bin/codec-bench" --codecs h264 --scenes page,scroll,drag,typing --loss 0 --seconds 10 \
    --threads "$cores" --json "$work/row.jsonl" > /dev/null
  python3 -I -c '
import json, sys
name, tuning, ablate = sys.argv[1:4]
with open(sys.argv[4], "a") as out:
    for line in open(sys.argv[5]):
        row = json.loads(line)
        row.update(variant=name, tuning=tuning, ablate=ablate)
        out.write(json.dumps(row) + "\n")' "$name" "$tuning" "$ablate" "$out/rows.jsonl" "$work/row.jsonl"
  echo "openh264-ablation: $name done" >&2
done

# The floor on the same cores: x264 ultrafast/zerolatency on the frames codec-bench codes.
if command -v x264 >/dev/null; then
  for s in page scroll drag typing; do
    "$bin/scene-dump" "$s" 300 "$work/$s.yuv"
    nice -n 10 taskset -c "0-$last" x264 --input-res 1920x1080 --input-csp i420 --fps 30 --demuxer raw \
      --preset ultrafast --tune zerolatency --threads "$cores" --sliced-threads --profile baseline --bitrate 8000 \
      --vbv-maxrate 8000 --vbv-bufsize 267 --keyint infinite -o /dev/null "$work/$s.yuv" 2>&1 |
      grep -E '^encoded' > "$work/$s.x264.txt" || true
    rm -f "$work/$s.yuv"
  done
fi

# Where the time goes: screen against camera usage on the scroll scene.
if command -v perf >/dev/null && perf record -q -o "$work/probe.data" -- true >/dev/null 2>&1; then
  for u in screen camera; do
    CMUX_OPENH264_TUNING="usage=$u" nice -n 10 taskset -c "0-$last" perf record -q -F 1999 -o "$work/$u.data" -- \
      "$bin/codec-bench" --codecs h264 --scenes scroll --loss 0 --seconds 10 --threads "$cores" > /dev/null 2>&1 || true
    perf report -q -i "$work/$u.data" --stdio --no-children --sort symbol 2>/dev/null | head -50 > "$out/perf-$u.txt" || true
  done
fi

python3 -I - "$out" "$work" "$machine" <<'PY'
import json, os, re, sys
out, work, machine = sys.argv[1:4]
rows = [json.loads(l) for l in open(f"{out}/rows.jsonl")]
scenes = ["page", "scroll", "drag", "typing"]
floor = {}
for s in scenes:
    p = f"{work}/{s}.x264.txt"
    if os.path.exists(p) and (m := re.search(r"([0-9.]+) fps", open(p).read())):
        floor[s] = round(1000.0 / float(m.group(1)), 2)
json.dump({"machine": machine, "x264_mean_ms": floor}, open(f"{out}/floor.json", "w"))
by = {}
for r in rows:
    by.setdefault(r["variant"], {})[r["scene"]] = r
f = lambda x: "-" if x is None else f"{x:.1f}"
lines = [f"Machine: {machine}. x264 floor (mean ms): " + ", ".join(f"{s} {floor[s]}" for s in floor), "",
         "| variant | " + " | ".join(f"{s} enc p50 ms" for s in scenes) + " | worst ratio vs floor | "
         + " | ".join(f"{s} PSNR dB" for s in scenes) + " | " + " | ".join(f"{s} Mbps" for s in scenes)
         + " | " + " | ".join(f"{s} on-time fps" for s in scenes) + " |",
         "|---" * (2 + 4 * 4) + "|"]
for name, sc in by.items():
    p50 = [sc.get(s, {}).get("encode_ms", {}).get("p50") for s in scenes]
    ratios = [p / floor[s] for p, s in zip(p50, scenes) if p is not None and s in floor]
    lines.append(f"| {name} | " + " | ".join(f(x) for x in p50)
                 + f" | {max(ratios):.2f} |" if ratios else f"| {name} | " + " | ".join(f(x) for x in p50) + " | - |")
    lines[-1] += " " + " | ".join(f(sc.get(s, {}).get("psnr_y_db", {}).get("mean")) for s in scenes) + " | " \
        + " | ".join(f(sc.get(s, {}).get("media_mbps")) for s in scenes) + " | " \
        + " | ".join(f(sc.get(s, {}).get("on_time_fps")) for s in scenes) + " |"
open(f"{out}/table.md", "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY
for u in screen camera; do
  [[ -s "$out/perf-$u.txt" ]] && { echo; echo "perf, $u usage, scroll:"; head -25 "$out/perf-$u.txt"; }
done
exit 0
