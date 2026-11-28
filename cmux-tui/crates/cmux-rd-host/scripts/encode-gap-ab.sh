#!/bin/bash
# Host encode A/B on a Mac: VideoToolbox encode time back to back (gap 0) vs with
# key-press gaps (gap 150 ms, about the r12e press cadence), with the
# MaximizePowerEfficiency hint unset (shipping default), 0 and 1, and a fourth arm, KEEPWARM:
# the hint unset and CMUX_RD_VT_KEEPWARM=1 (warm-up frames before the first real one).
# Usage (from the repo root, on macOS): bash cmux-tui/crates/cmux-rd-host/scripts/encode-gap-ab.sh
# Prints one summary line per cell; raw JSON lines go to ${FAST_CHECKS_OUT:-/tmp}/encode-gap-ab.jsonl.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(uname)" = Darwin ] || { echo "encode-gap-ab: needs macOS (VideoToolbox)" >&2; exit 2; }
cargo build --release --bin cmux-rd 2>&1 | tail -3
bin=${CARGO_TARGET_DIR:-$PWD/target}/release/cmux-rd
sysctl -n machdep.cpu.brand_string
out=${FAST_CHECKS_OUT:-/tmp}/encode-gap-ab.jsonl
: > "$out"
run() { # pw w h gap n workload
  local pw=$1; shift
  case "$pw" in
    unset) env -u CMUX_RD_VT_POWER_EFFICIENT -u CMUX_RD_VT_KEEPWARM "$bin" encode-selftest "$@" ;;
    KEEPWARM) env -u CMUX_RD_VT_POWER_EFFICIENT CMUX_RD_VT_KEEPWARM=1 "$bin" encode-selftest "$@" ;;
    *) env -u CMUX_RD_VT_KEEPWARM CMUX_RD_VT_POWER_EFFICIENT="$pw" "$bin" encode-selftest "$@" ;;
  esac
}
for size in 1920x1080 3024x1964; do
  w=${size%x*}; h=${size#*x}
  for gap in 0 150; do
    n=120; [ "$gap" -gt 0 ] && n=60
    for pw in unset 0 1 KEEPWARM; do
      for wl in type text; do
        run "$pw" --codec videotoolbox --width "$w" --height "$h" --frames "$n" --gap-ms "$gap" --workload "$wl" | tail -1 >> "$out"
      done
    done
  done
done
python3 -I - "$out" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    d = json.loads(line); e = d["encode_ms"]
    print(d["size"], "gap", d["gap_ms"], "pw", d["power_efficient"], "warm", d.get("keepwarm"), d["workload"],
          "enc p50 %.2f p95 %.2f max %.2f" % (e["p50"], e["p95"], e["max"]))
PY
