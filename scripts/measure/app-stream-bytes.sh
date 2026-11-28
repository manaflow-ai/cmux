#!/usr/bin/env bash
# app-stream-bytes (CMUX-571): what acpmux sends the app's chat panes while chats stream, by message
# kind, shown and hidden panes apart, and the daemon's CPU for it.
#
# Leo, 2026-11-16: "for ios i mean but i guess you can look at the bandwidth of the regar app too".
#
# Runs cmux-tui/crates/acpmux/tests/app_stream_bytes.rs `app_stream_bytes_bench` (a real daemon with
# stand-in agents, one WebSocket per chat pane as the app opens them, every chat streaming) in both
# arms of the same build: quiet=0 attaches as the app did before `quietHidden`, quiet=1 as it does now.
# Each round prints one `app-stream-bytes: {json}` line (scripts/bench/benches/app_stream_bytes.py).
#
#   cmux-ci test -- bash scripts/measure/app-stream-bytes.sh [rounds=3] [chats=8] [shown=2] [ticks=400] [tick_ms=10]
#   scripts/bench/cmux-bench app-stream-bytes --import LOG
set -o pipefail
rounds=3
for arg in "$@"; do
  case "$arg" in
    rounds=*) rounds="${arg#rounds=}" ;;
    chats=*) export ACPMUX_BENCH_CHATS="${arg#chats=}" ;;
    shown=*) export ACPMUX_BENCH_SHOWN="${arg#shown=}" ;;
    ticks=*) export ACPMUX_BENCH_TICKS="${arg#ticks=}" ;;
    tick_ms=*) export ACPMUX_BENCH_TICK_MS="${arg#tick_ms=}" ;;
    *) echo "app-stream-bytes: unknown argument $arg" >&2; exit 2 ;;
  esac
done
cd "$(dirname "$0")/../../cmux-tui" || exit 1
cargo test -p acpmux --release --test app_stream_bytes --no-run || exit 1
rc=0
for round in $(seq 1 "$rounds"); do
  for quiet in 0 1; do
    out="$(ACPMUX_BENCH_QUIET=$quiet cargo test -p acpmux --release --test app_stream_bytes app_stream_bytes_bench \
      -- --ignored --nocapture 2>&1)"
    status=$?
    line="$(grep '^app-stream-bytes' <<<"$out")"
    if [[ $status -ne 0 || -z "$line" ]]; then
      echo "app-stream-bytes: round $round quiet=$quiet failed (exit $status)" >&2
      tail -20 <<<"$out" >&2
      rc=1
      continue
    fi
    echo "$line"
  done
done
exit $rc
