#!/usr/bin/env bash
# Before and after a send change, from one harness on one machine: bench/send-status-shift.bench.ts at
# this checkout's pane, then at BASE's pane (`src` checked out from BASE, the bench file kept), in its
# three modes (an open chat, a new chat's composer, the New Tab page). Writes before-MODE.json and
# after-MODE.json to OUT (default $FAST_CHECKS_OUT) and restores `src` when done.
#   bench/send-status-ab.sh BASE [rounds=3]
#   cmux-ci test --setup playwright -- bash webviews/bench/send-status-ab.sh <base sha>
set -euo pipefail
base="${1:?usage: send-status-ab.sh BASE [rounds]}"
rounds="${2:-3}"
cd "$(dirname "$0")/.."
out="${OUT:-${FAST_CHECKS_OUT:-$(mktemp -d)}}"
mkdir -p "$out"
run() {
  local label="$1" mode
  for mode in open new-chat new-tab; do
    local flag=()
    [ "$mode" != open ] && flag=("--$mode")
    echo "=== $label $mode"
    bun bench/send-status-shift.bench.ts "$rounds" --engines chromium,webkit --think-ms 1500 --start-ms 1500 \
      "${flag[@]}" --json "$out/$label-$mode.json" || echo "=== $label $mode FAILED"
  done
}
run after
git cat-file -e "$base^{commit}" 2>/dev/null || git fetch -q --depth=1 origin "$base"
trap 'git checkout HEAD -- src' EXIT
git checkout "$base" -- src
run before
echo "send-status-ab: wrote $out"
