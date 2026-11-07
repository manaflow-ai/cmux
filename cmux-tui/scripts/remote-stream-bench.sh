#!/usr/bin/env bash
# Runs cmux-wg's remote_stream_bench example over every path, on a clean
# loopback and on shaped ones, and prints one JSON line per run.
#
#   cmux-tui/scripts/remote-stream-bench.sh [OUT.jsonl]
#
# Shaping uses netem on lo, so it needs passwordless sudo (a CI runner, not a
# workstation). Every packet crosses lo once, so DELAY_MS one way per packet
# gives an RTT of twice it; loss applies to each packet. The trap removes the
# qdisc on every exit. Environment: SECONDS_PER_RUN (default 10), FPS (60),
# FRAME_BYTES (3500, a typing-sized H.264 delta), KEYFRAME_BYTES (200000),
# BULK_BYTES (16 MiB), PROFILES (default list below: name:delay_ms:loss_pct).
set -euo pipefail

cd "$(dirname "$0")/.."
out="${1:-/dev/stdout}"
seconds="${SECONDS_PER_RUN:-10}"
fps="${FPS:-60}"
frame="${FRAME_BYTES:-3500}"
keyframe="${KEYFRAME_BYTES:-200000}"
bulk="${BULK_BYTES:-16777216}"
profiles="${PROFILES:-clean:0:0 rtt50:25:0 rtt50-loss1:25:1 rtt150-loss1:75:1 rtt150-loss3:75:3}"

cargo build --release -q -p cmux-wg --example remote_stream_bench
bin="target/release/examples/remote_stream_bench"

shaped=0
unshape() {
  if [ "$shaped" = 1 ]; then
    sudo -n tc qdisc del dev lo root 2>/dev/null || true
    shaped=0
  fi
}
trap unshape EXIT

for profile in $profiles; do
  IFS=: read -r name delay loss <<<"$profile"
  unshape
  if [ "$delay" != 0 ] || [ "$loss" != 0 ]; then
    sudo -n tc qdisc add dev lo root netem delay "${delay}ms" loss "${loss}%" limit 100000
    shaped=1
  fi
  for path in tcp wg-tcp wg-dgram; do
    line="$("$bin" --path "$path" --seconds "$seconds" --fps "$fps" --frame-bytes "$frame" \
      --keyframe-bytes "$keyframe" --bulk-bytes "$bulk" 2>/dev/null || echo '{}')"
    printf '{"profile":"%s","rtt_ms":%s,"loss_pct":%s,"result":%s}\n' \
      "$name" "$((delay * 2))" "$loss" "$line" >>"$out"
  done
done
