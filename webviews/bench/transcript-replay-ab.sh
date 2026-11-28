#!/usr/bin/env bash
# The long chat's live replay before and after a change, from one harness on one machine: bench/transcript-replay.bench.ts
# --only long (RENDERS=1 SPLIT=1: the per-record-kind ms, renders and hidden-row pane renders the perf cron's
# `transcript_replay.long.*` rows carry) at this checkout's pane and at BASE's pane (a detached worktree of BASE with
# this checkout's bench and node_modules, removed when done), interleaved ROUNDS times.
#   bench/transcript-replay-ab.sh BASE [rounds=1]
# The order of the sides turns every round, so a runner warming or tiring lands on both alike. Each side's run log
# goes to OUT (default $FAST_CHECKS_OUT) as `<before|after>-<round>.log`; scripts/ci/transcript_replay_report.py reads
# them. BASE `-` measures this checkout only. With DURESS=1 and stress-ng on PATH, each side also takes one reading of
# scripts/measure/replay-under-load.sh --cores 2 (`duress-<side>.json`), after the rounds.
set -euo pipefail
base="${1:?usage: transcript-replay-ab.sh BASE [rounds]}"
rounds="${2:-1}"
cd "$(dirname "$0")/.."
out="${OUT:-${FAST_CHECKS_OUT:-$(mktemp -d)}}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
here="$(pwd)"
rel="$(git rev-parse --show-prefix)"
sides=(after)
declare -A dirs=([after]="$here")
trees=()
trap 'for t in "${trees[@]}"; do git -C "$here" worktree remove --force "$t" 2>/dev/null || true; done' EXIT
if [ "$base" != - ]; then
  depth=()
  [ "$(git rev-parse --is-shallow-repository)" = true ] && depth=(--depth=1)
  sha="$(git rev-parse --verify -q "$base^{commit}" || { git fetch -q "${depth[@]}" origin "$base" && git rev-parse "$base^{commit}"; })"
  tree="$(mktemp -d)/before"
  trees+=("$tree")
  git worktree add -q --detach "$tree" "$sha"
  rm -rf "$tree/$rel/bench"
  cp -R "$here/bench" "$tree/$rel/bench"
  ln -s "$here/node_modules" "$tree/$rel/node_modules"
  (cd "$tree/$rel" && bun scripts/pages/gen-strings.mjs --best-effort >/dev/null)
  dirs[before]="$tree/$rel"
  sides=(before after)
  echo "=== side before at $sha"
fi
# The 1-minute load average per core at a run's start and end (`<side>-<round>.load`): the report reads a side's ms as
# noise when the host was this busy, not as a regression.
load_per_core() { awk -v n="$(nproc)" '{ printf "%.2f\n", $1 / n }' /proc/loadavg; }
run() {
  local side="$1" round="$2" log="$out/$1-$2.log"
  echo "=== $side round $round"
  load_per_core >"$out/$1-$2.load"
  (cd "${dirs[$side]}" && RENDERS=1 SPLIT=1 timeout 900 bun bench/transcript-replay.bench.ts --only long) \
    >"$log" 2>&1 || echo "=== $side round $round FAILED (status $?)"
  load_per_core >>"$out/$1-$2.load"
  grep -E '^transcript-replay: (long|BUDGET MISS)' "$log" | cut -c1-200 || true
}
n=${#sides[@]}
for round in $(seq 1 "$rounds"); do
  for k in $(seq 0 $((n - 1))); do
    run "${sides[$(((k + round - 1) % n))]}" "$round"
  done
done
if [ "${DURESS:-0}" = 1 ] && command -v stress-ng >/dev/null; then
  for side in "${sides[@]}"; do
    root="$(cd "${dirs[$side]}" && git rev-parse --show-toplevel)"
    echo "=== $side duress"
    (cd "$root" && timeout 600 bash scripts/measure/replay-under-load.sh --cores 2 --out "$out/duress-$side.json") \
      >"$out/duress-$side.log" 2>&1 || echo "=== $side duress FAILED"
    tail -1 "$out/duress-$side.log" || true
  done
fi
echo "transcript-replay-ab: wrote $out"
