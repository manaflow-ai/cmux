#!/usr/bin/env bash
# Repro for the chief_move_return round-trip flake (red on 2 vCPU Blacksmith runners only):
# the test file N times on 2 CPUs (taskset), printing the watcher's log on each failure.
# usage: scripts/measure/chief-move-flake.sh [N]
set -uo pipefail
n="${1:-30}"
cd "$(git rev-parse --show-toplevel)/Native/OptChat/optchat-chief"
nproc; command -v cargo || { echo "no cargo"; exit 2; }
cargo test --locked --test chief_move_return --no-run 2>&1 | tail -3
bin=$(ls -t target/debug/deps/chief_move_return-* | grep -v '\.d$' | head -1)
pin=""; command -v taskset >/dev/null && pin="taskset -c 0,1"
fails=0
for i in $(seq 1 "$n"); do
  start=$(date +%s)
  if ! out=$(CARGO_BIN_EXE_optchat-chief=x $pin "$bin" --test-threads=2 2>&1); then
    fails=$((fails+1)); echo "=== run $i FAILED after $(( $(date +%s)-start ))s"; echo "$out" | tail -40
  else
    echo "run $i ok $(( $(date +%s)-start ))s"
  fi
done
echo "CHIEF-FLAKE: $fails of $n failed"
