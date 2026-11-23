#!/usr/bin/env bash
# Runs cmux-wg's remote_stream_bench example over every path, on a clean
# loopback and on shaped ones, and prints one JSON line per run.
#
#   cmux-tui/scripts/remote-stream-bench.sh [OUT.jsonl]
#
# Shaping happens inside the bench: the WireGuard paths' UDP goes through an
# in-process link that adds half of RTT_MS each way and drops LOSS_PCT of
# datagrams in each direction (fleet runner kernels have no netem). Kernel TCP
# runs only on the clean profile. Environment: SECONDS_PER_RUN (default 10),
# FPS (60), FRAME_BYTES (3500, a typing-sized H.264 delta), KEYFRAME_BYTES
# (200000), BULK_BYTES (16 MiB), PROFILES (default list below:
# name:rtt_ms:loss_pct).
set -euo pipefail

cd "$(dirname "$0")/.."
out="${1:-/dev/stdout}"
seconds="${SECONDS_PER_RUN:-10}"
fps="${FPS:-60}"
frame="${FRAME_BYTES:-3500}"
keyframe="${KEYFRAME_BYTES:-200000}"
bulk="${BULK_BYTES:-16777216}"
profiles="${PROFILES:-clean:0:0 rtt50:50:0 rtt150:150:0 rtt50-loss1:50:1 rtt150-loss1:150:1 rtt150-loss3:150:3}"

cargo build --release -q -p cmux-wg --example remote_stream_bench
bin="${CARGO_TARGET_DIR:-target}/release/examples/remote_stream_bench"

for profile in $profiles; do
  IFS=: read -r name rtt loss <<<"$profile"
  paths="wg-tcp wg-dgram"
  if [ "$rtt" = 0 ] && [ "$loss" = 0 ]; then
    paths="tcp $paths"
  fi
  for path in $paths; do
    line="$("$bin" --path "$path" --seconds "$seconds" --fps "$fps" --frame-bytes "$frame" \
      --keyframe-bytes "$keyframe" --bulk-bytes "$bulk" --rtt-ms "$rtt" --loss-pct "$loss" ||
      echo '{}')"
    printf '{"profile":"%s","result":%s}\n' "$name" "$line" >>"$out"
  done
done
