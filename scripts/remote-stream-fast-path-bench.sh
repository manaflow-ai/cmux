#!/usr/bin/env bash
# The remote_stream_bench desktop workload over two paths to one peer (a fast
# local path and a slow relayed one), with the fast path cut partway through,
# and print one JSON line per run.
#
#   scripts/remote-stream-fast-path-bench.sh [OUT.jsonl]
#
# Rows: the fast path alone, the relay alone, both paths, and both paths with
# the fast one cut DROP_AT seconds in. `longest_frame_gap_ms` is the stall a
# cut costs; `final_path` is the path index carrying the stream at the end.
#
# Env: FAST_RTT, SLOW_RTT (ms), SECONDS_PER_RUN, DROP_AT, REPEAT, BULK_BYTES,
# BENCH_PATH (wg-tcp: one multipath underlay; wg-mesh: two `WgMesh` ends, the
# `cmux link` and acpmux engine).
set -euo pipefail

out_dir="${FAST_CHECKS_OUT:-}"
out="${1:-${out_dir:-/tmp}/remote-stream-fast-path.jsonl}"
mkdir -p "$(dirname "$out")"
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")" # the script changes directory below
: >"$out"
cd "$(dirname "$0")/../cmux-tui"

fast="${FAST_RTT:-2}"
slow="${SLOW_RTT:-40}"
secs="${SECONDS_PER_RUN:-12}"
drop="${DROP_AT:-4}"
repeat="${REPEAT:-3}"
bulk="${BULK_BYTES:-16000000}"
path="${BENCH_PATH:-wg-tcp}"

cargo build --release -p cmux-wg --example remote_stream_bench >&2
# CARGO_TARGET_DIR (set on the fleet) moves the binary; ask cargo where it is.
target_dir="$(cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
bench="$target_dir/release/examples/remote_stream_bench"
[ -x "$bench" ] || { echo "no bench binary at $bench" >&2; exit 1; }

run() { # label, args...
  local label="$1"
  shift
  local line
  line="$(timeout 200 "$bench" --path "$path" --seconds "$secs" --bulk-bytes "$bulk" "$@" 2>/dev/null || true)"
  [ -n "$line" ] || line='{"error":"no output"}'
  printf '{"row":"%s",%s\n' "$label" "${line#\{}" | tee -a "$out"
}

for _ in $(seq "$repeat"); do
  run fast-only --paths "lan:$fast"
  run relay-only --paths "relay:$slow"
  run both --paths "lan:$fast,relay:$slow"
  run both-fast-cut --paths "lan:$fast,relay:$slow" --drop-at "$drop:0"
done
