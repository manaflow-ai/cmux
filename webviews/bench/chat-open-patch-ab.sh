#!/usr/bin/env bash
# Interleaved A/B of chat-open attach_to_latest in one checkout: head (as checked out) vs base (PATCH reverted),
# PAIRS alternations x ROUNDS rounds, order turned each pair. Prints each side's per-round ms and medians.
#   bash webviews/bench/chat-open-patch-ab.sh PATCH [pairs=6] [rounds=4] [turns=300]
set -euo pipefail
patch="$(realpath "$1")"; pairs="${2:-6}"; rounds="${3:-4}"; turns="${4:-300}"
cd "$(dirname "$0")/.."
reverted=0
trap '[ $reverted = 1 ] && git apply "$patch" || true' EXIT
run() { bun bench/chat-open.bench.ts "$rounds" "$turns" 2>&1 | grep '^per round:' | sed -E 's/.*attach_to_latest ms ([0-9. ]+);.*/\1/'; }
base=(); head=()
for i in $(seq "$pairs"); do
  order="head base"; [ $((i % 2)) = 0 ] && order="base head"
  for side in $order; do
    if [ "$side" = base ]; then git apply -R "$patch"; reverted=1; fi
    line="$(run)"; echo "$side $line"
    if [ "$side" = base ]; then git apply "$patch"; reverted=0; base+=($line); else head+=($line); fi
  done
done
med() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END {print (NR%2 ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2)}'; }
echo "median base $(med "${base[@]}") head $(med "${head[@]}") (n=${#base[@]} each)"
