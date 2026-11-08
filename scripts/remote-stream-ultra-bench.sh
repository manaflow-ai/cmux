#!/usr/bin/env bash
# Replay the remote_stream_bench desktop workload over emulated links, with
# cmux-wg's ultra transport mode off and on, and print one JSON line per run.
#
#   scripts/remote-stream-ultra-bench.sh [OUT.jsonl]
#
# Two link emulators:
# - the bench's in-process UDP link (--rtt-ms, --loss-pct: fixed delay,
#   uniform random loss each way), for the full RTT x loss x mode matrix;
# - Linux netem on loopback (delay with jitter, loss) when `sudo -n tc ... netem` works,
#   for a jitter row and for kernel TCP, which the in-process link cannot shape.
#
# Env: RTTS, LOSSES, MODES, SECONDS_PER_RUN, BULK_BYTES override the matrix;
# DGRAM=0 and NETEM=0 skip those rows (RTTS="" skips the in-process grid).
set -euo pipefail

out_dir="${FAST_CHECKS_OUT:-}"
out="${1:-${out_dir:-/tmp}/remote-stream-ultra.jsonl}"
mkdir -p "$(dirname "$out")"
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")" # the script changes directory below
: >"$out"
cd "$(dirname "$0")/../cmux-tui"

rtts="${RTTS-30 100 300}"
losses="${LOSSES:-0 1 3 5 10}"
# A mode is a CMUX_WG_ULTRA value; "+nocc" also sets CMUX_WG_ULTRA_CC=none.
modes="${MODES:-off dup fec:8:2 fec:8:2+nocc rs:8:4 rs:4:4}"
secs="${SECONDS_PER_RUN:-8}"
bulk="${BULK_BYTES:-4000000}"

cargo build --release -p cmux-wg --example remote_stream_bench >&2
# CARGO_TARGET_DIR (set on the fleet) moves the binary; ask cargo where it is.
target_dir="$(cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
bench="$target_dir/release/examples/remote_stream_bench"
[ -x "$bench" ] || { echo "no bench binary at $bench" >&2; exit 1; }

run() { # mode, label, args...
  local mode="$1" label="$2"
  shift 2
  local line
  local ultra="${mode%+nocc}" cc=cubic
  [ "$ultra" = "$mode" ] || cc=none
  line="$(CMUX_WG_ULTRA="$ultra" CMUX_WG_ULTRA_CC="$cc" timeout 150 "$bench" --seconds "$secs" --bulk-bytes "$bulk" "$@" 2>/dev/null || true)"
  [ -n "$line" ] || line='{"error":"no output"}'
  printf '{"mode":"%s","link":"%s",%s\n' "$mode" "$label" "${line#\{}" | tee -a "$out"
}

for rtt in $rtts; do
  for loss in $losses; do
    for mode in $modes; do
      run "$mode" inproc --path wg-tcp --rtt-ms "$rtt" --loss-pct "$loss"
    done
  done
done
[ "${DGRAM:-1}" = 1 ] && for loss in $losses; do
  for mode in off fec:8:2; do
    run "$mode" inproc --path wg-dgram --rtt-ms 100 --loss-pct "$loss"
  done
done

if [ "${NETEM:-1}" != 1 ]; then
  :
elif sudo -n tc qdisc replace dev lo root netem delay 0ms >/dev/null 2>&1; then
  netem() { sudo -n tc qdisc replace dev lo root netem "$@"; }
  trap 'sudo -n tc qdisc del dev lo root 2>/dev/null || true' EXIT
  # Loopback netem shapes both directions: 50 ms each way is a 100 ms RTT.
  for loss in 0 1 3; do
    netem delay 50ms 10ms distribution normal loss "${loss}%"
    run off "netem-100ms-j10-l${loss}" --path tcp
    for mode in off fec:8:2 fec:8:2+nocc; do
      run "$mode" "netem-100ms-j10-l${loss}" --path wg-tcp
    done
  done
  sudo -n tc qdisc del dev lo root || true
else
  echo '{"note":"no sudo tc netem (module or sudo missing): netem rows skipped"}' | tee -a "$out"
fi
