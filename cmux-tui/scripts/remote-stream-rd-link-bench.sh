#!/usr/bin/env bash
# Before and after for Cloud desktop media on datagrams (cmuxterm-hq#7976):
# cmux-wg's remote_stream_bench on `wg-tcp` (one TCP stream through the
# lossy link, the stand-in for today's carrier stream, TCP on every hop)
# and on `rd-link` (rd FEC, NACK resends and input as datagrams sealed by
# cmux-rd-link), interleaved A B, RUNS times per cell. Prints one JSON line
# per run, then a table of medians.
#
#   cmux-tui/scripts/remote-stream-rd-link-bench.sh [OUT.jsonl]
#
# Environment: RTTS (default "30 100 300", ms), LOSSES ("0 1 3", %), RUNS (4),
# SECONDS_PER_RUN (8), FPS (60), FRAME_BYTES (3500), KEYFRAME_BYTES (200000),
# BULK_BYTES (0: no bulk transfer after the stream), EXTRA_ARGS (passed to
# every run).
set -euo pipefail

cd "$(dirname "$0")/.."
out="${1:-}"
seconds="${SECONDS_PER_RUN:-8}"
fps="${FPS:-60}"
frame="${FRAME_BYTES:-3500}"
keyframe="${KEYFRAME_BYTES:-200000}"
bulk="${BULK_BYTES:-0}"
runs="${RUNS:-4}"
rtts="${RTTS:-30 100 300}"
losses="${LOSSES:-0 1 3}"
read -r -a extra <<<"${EXTRA_ARGS:-}"

cargo build --release -q -p cmux-wg --example remote_stream_bench
bin="${CARGO_TARGET_DIR:-target}/release/examples/remote_stream_bench"
lines="$(mktemp)"
trap 'rm -f "$lines"' EXIT

for rtt in $rtts; do
  for loss in $losses; do
    for run in $(seq 1 "$runs"); do
      for path in wg-tcp rd-link; do
        line="$("$bin" --path "$path" --seconds "$seconds" --fps "$fps" --frame-bytes "$frame" \
          --keyframe-bytes "$keyframe" --bulk-bytes "$bulk" --rtt-ms "$rtt" --loss-pct "$loss" \
          "${extra[@]}" || echo '{}')"
        printf '{"rtt_ms":%s,"loss_pct":%s,"run":%s,"arm":"%s","result":%s}\n' \
          "$rtt" "$loss" "$run" "$path" "$line" | tee -a "$lines"
      done
    done
  done
done

if [ -n "$out" ]; then
  cp "$lines" "$out"
fi

python3 - "$lines" <<'EOF'
import json, statistics, sys

cells = {}
for raw in open(sys.argv[1]):
    row = json.loads(raw)
    result = row["result"]
    key = (row["rtt_ms"], row["loss_pct"])
    arm = cells.setdefault(key, {}).setdefault(row["arm"], [])
    photon = result.get("input_to_photon_ms") or {}
    arm.append((photon.get("p50"), photon.get("p99"), result.get("longest_frame_gap_ms"),
                result.get("frames_received")))

def median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None

def show(value):
    return "-" if value is None else f"{value:.0f}"

print("| RTT ms | loss % | wg-tcp p50 / p99 / gap | rd-link p50 / p99 / gap | runs |")
print("|---|---|---|---|---|")
for (rtt, loss), arms in sorted(cells.items()):
    parts = []
    for name in ("wg-tcp", "rd-link"):
        rows = arms.get(name, [])
        parts.append(" / ".join(show(median([r[i] for r in rows])) for i in range(3)))
    n = min(len(arms.get("wg-tcp", [])), len(arms.get("rd-link", [])))
    print(f"| {rtt} | {loss} | {parts[0]} | {parts[1]} | {n} |")
EOF
