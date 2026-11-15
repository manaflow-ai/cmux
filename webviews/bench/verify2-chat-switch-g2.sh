#!/usr/bin/env bash
# TEMPORARY (perf 24569 group 2): more samples, god chat-open rows, the flat bench again, and video/screenshots.
# Delete before merge.
#   bench/verify2-chat-switch-g2.sh BEFORE_SHA AFTER_SHA PRE_42298_SHA
set -uo pipefail
before="$1" after="$2" pre="$3"
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
snaps="${FAST_CHECKS_OUT:-/tmp/bcs-out}/snaps"
echo "== chat-switch god, 7 rounds, one at a time (with video and screenshots of the measured round)"
OUT_SUB=switch7 PAR=1 ROUNDS=7 SNAP_ROOT="$snaps" bash bench/bisect-chat-switch.sh \
  "$pre:god" "$before:both" "$after:both" | grep -E '^(DONE|FAIL)'
echo "== chat-open god before/after, one at a time"
OUT_SUB=open PAR=1 BENCH=chat-open.bench.ts BENCH_ARGS="3 300" bash bench/bisect-chat-switch.sh \
  "$pre:god" "$before:god" "$after:god" "$before:god:r.2" "$after:god:r.2" | grep -E '^(DONE|FAIL)'
echo "== chat-100k-flat again (CASES=main), after first this time"
OUT_SUB=flat2 PAR=1 CASES=main BENCH=chat-100k-flat.bench.ts BENCH_ARGS="100000 20" BENCH_TIMEOUT=1500 \
  bash bench/bisect-chat-switch.sh "$after:plain" "$before:plain" | grep -E '^(DONE|FAIL)'
