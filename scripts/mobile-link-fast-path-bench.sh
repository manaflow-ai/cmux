#!/usr/bin/env bash
# The remote desktop workload (60 fps of 3.5 KB frames, an input every
# 20 ms) over the iPhone mobile link's WireGuard tunnel, in one process,
# with a direct path and a TURN relay, and the direct path cut partway
# through. Prints one JSON line per run (examples/link_stream_bench.rs).
#
#   scripts/mobile-link-fast-path-bench.sh [OUT.jsonl]
#
# Rows: the direct path alone, the relay alone, both, and both with the
# direct path cut CUT_AT seconds in. `longest_frame_gap_ms` is the stall a
# cut costs; `final_path` is the phone's path at the end.
#
# Env: LAN_RTT, RELAY_RTT (ms), SECONDS_PER_RUN, CUT_AT, REPEAT; BENCH_BIN
# runs an already built bench (two builds compared in one job), and
# BUILD_LABEL names it in each line.
set -euo pipefail

out_dir="${FAST_CHECKS_OUT:-}"
out="${1:-${out_dir:-/tmp}/mobile-link-fast-path.jsonl}"
mkdir -p "$(dirname "$out")"
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")" # the script changes directory below
touch "$out"
cd "$(dirname "$0")/../cmux-next-ios/rust"

lan="${LAN_RTT:-2}"
relay="${RELAY_RTT:-40}"
secs="${SECONDS_PER_RUN:-12}"
cut="${CUT_AT:-4}"
repeat="${REPEAT:-3}"
label="${BUILD_LABEL:-}"

bench="${BENCH_BIN:-}"
if [ -z "$bench" ]; then
  cargo build --release -p cmux-mobile-link --example link_stream_bench >&2
  # CARGO_TARGET_DIR (set on the fleet) moves the binary; ask cargo where it is.
  target_dir="$(cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
  bench="$target_dir/release/examples/link_stream_bench"
fi
[ -x "$bench" ] || { echo "no bench binary at $bench" >&2; exit 1; }

run() { # row label, args...
  local name="$1"
  shift
  local line
  line="$(timeout 120 "$bench" --lan-rtt "$lan" --relay-rtt "$relay" --seconds "$secs" "$@" 2>/dev/null || true)"
  [ -n "$line" ] || line='{"error":"no output"}'
  printf '{"build":"%s","name":"%s",%s\n' "$label" "$name" "${line#\{}" | tee -a "$out"
}

for _ in $(seq "$repeat"); do
  run lan-only --row lan-only
  run relay-only --row relay-only
  run both --row both
  run both-lan-cut --row both --cut-at "$cut"
done
