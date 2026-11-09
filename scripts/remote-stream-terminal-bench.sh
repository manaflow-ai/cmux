#!/usr/bin/env bash
# Keystroke-to-echo over today's carrier (kernel TCP) and over UDP paths, on
# a lossy, delayed link: the remote_stream_bench terminal workload.
#
#   scripts/remote-stream-terminal-bench.sh [OUT.jsonl]
#
# Arms, run interleaved (A B C ... A B C ...) in every cell:
# - tcp:     kernel TCP through a tun link in its own network namespace
#            (`unshare -rn`), the stand-in for the carrier, which is kernel
#            TCP on every hop;
# - wg-off:  smoltcp TCP inside cmux-wg over UDP, no repair;
# - wg-MODE: the same with CMUX_WG_ULTRA=MODE on both ends.
#
# Env: RTTS, LOSSES, ARMS, RUNS, SECONDS_PER_RUN, KEY_MS, OUTPUT_BPS override
# the matrix. Prints one JSON line per run and a table of medians at the end.
set -euo pipefail

out_dir="${FAST_CHECKS_OUT:-}"
out="${1:-${out_dir:-/tmp}/remote-stream-terminal.jsonl}"
mkdir -p "$(dirname "$out")"
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
: >"$out"
cd "$(dirname "$0")/../cmux-tui"

rtts="${RTTS-30 100 300}"
losses="${LOSSES:-0 1 3}"
arms="${ARMS:-tcp wg-off wg-fec:8:2 wg-dup}"
runs="${RUNS:-4}"
secs="${SECONDS_PER_RUN:-15}"
key_ms="${KEY_MS:-50}"
output_bps="${OUTPUT_BPS:-0}"

cargo build --release -p cmux-wg --example remote_stream_bench >&2
target_dir="$(cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
bench="$target_dir/release/examples/remote_stream_bench"
[ -x "$bench" ] || { echo "no bench binary at $bench" >&2; exit 1; }

run() { # arm, rtt, loss, run
  local arm="$1" rtt="$2" loss="$3" index="$4" line
  local common=(--workload terminal --seconds "$secs" --bulk-bytes 0 --key-interval-ms "$key_ms"
    --output-bytes-per-s "$output_bps" --rtt-ms "$rtt" --loss-pct "$loss")
  case "$arm" in
    tcp) line="$(timeout 120 unshare -rn "$bench" --path tcp-tun "${common[@]}" 2>/dev/null || true)" ;;
    wg-*)
      local mode="${arm#wg-}"
      line="$(CMUX_WG_ULTRA="$mode" timeout 120 "$bench" --path wg-tcp "${common[@]}" 2>/dev/null || true)"
      ;;
  esac
  [ -n "$line" ] || line='{"error":"no output"}'
  printf '{"arm":"%s","run":%s,%s\n' "$arm" "$index" "${line#\{}" | tee -a "$out"
}

for rtt in $rtts; do
  for loss in $losses; do
    for index in $(seq 1 "$runs"); do
      for arm in $arms; do
        run "$arm" "$rtt" "$loss" "$index"
      done
    done
  done
done

python3 - "$out" <<'PY'
import json, statistics, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
cells = {}
for row in rows:
    if "echo_ms" not in row or not isinstance(row.get("echo_ms"), dict):
        continue
    key = (row["rtt_ms"], row["loss_pct"], row["arm"])
    cells.setdefault(key, []).append(row)
arms = []
for row in rows:
    if row.get("arm") and row["arm"] not in arms:
        arms.append(row["arm"])
med = lambda xs: statistics.median(xs) if xs else float("nan")
print("| RTT ms | loss % | " + " | ".join(f"{a} p50 / p99 / stall" for a in arms) + " | runs |")
print("|---|---|" + "---|" * len(arms) + "---|")
for rtt, loss in sorted({(k[0], k[1]) for k in cells}):
    parts, n = [], 0
    for arm in arms:
        got = cells.get((rtt, loss, arm), [])
        n = max(n, len(got))
        p50 = med([r["echo_ms"]["p50"] for r in got])
        p99 = med([r["echo_ms"]["p99"] for r in got])
        stall = med([r["longest_stall_ms"] for r in got])
        parts.append(f"{p50:.0f} / {p99:.0f} / {stall:.0f}")
    print(f"| {rtt} | {loss:g} | " + " | ".join(parts) + f" | {n} |")
PY
