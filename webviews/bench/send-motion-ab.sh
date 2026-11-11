#!/usr/bin/env bash
# Before and after numbers for the send's motion from one harness (Leo, 2026-11-09: "i hate the way when i send off
# a message it seems to move up and under your current running tool call or whatever"; "the prompt sending animation
# feels sluggish ... everything's just a bit slow rn"). Runs the send bench (send-status-shift.bench.ts) in four
# modes: open (an idle chat), mid-turn (a steer while a tool call runs), and each under 12 ms of main-thread load a
# frame; then the scroll readjust bench (transcript-scroll-readjust.bench.ts). First on this checkout's src ("after"),
# then on BASE's src with this checkout's benches ("before"); src is put back on exit.
#   bench/send-motion-ab.sh BASE [rounds=3]
# Writes each run's JSON and log to $OUT (default a new temporary directory) and prints every PERF_ROW, labelled.
set -euo pipefail
base="${1:?usage: send-motion-ab.sh BASE [rounds]}"
rounds="${2:-3}"
cd "$(dirname "$0")/.."
# The base's src replaces this one's for the "before" run: refuse to run over uncommitted or untracked work in it.
if [ -n "$(git status --porcelain -- src)" ]; then
  echo "send-motion-ab: src has uncommitted changes; commit them first" >&2
  exit 2
fi
out="${OUT:-${FAST_CHECKS_OUT:-$(mktemp -d)}}"
mkdir -p "$out"
echo "send-motion-ab: writing to $out"

run() {
  local label="$1" mode
  local -a flags
  for mode in open mid-turn open-load12 mid-turn-load12; do
    flags=()
    case "$mode" in mid-turn*) flags+=(--mid-turn) ;; esac
    case "$mode" in *-load12) flags+=(--load 12) ;; esac
    echo "=== $label $mode"
    if ! bun bench/send-status-shift.bench.ts "$rounds" --engines chromium,webkit --think-ms 1500 \
      ${flags[@]+"${flags[@]}"} --json "$out/$label-$mode.json" 2>&1 | tee "$out/$label-$mode.log"; then
      echo "=== $label $mode FAILED"
    fi
  done
  echo "=== $label scroll-readjust"
  if ! bun bench/transcript-scroll-readjust.bench.ts 3000 "$rounds" --engines webkit,chromium \
    --json "$out/$label-scroll-readjust.json" 2>&1 | tee "$out/$label-scroll-readjust.log"; then
    echo "=== $label scroll-readjust FAILED"
  fi
}

run after
# A full clone stays full: --depth only where the checkout is already shallow.
depth=()
[[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
git cat-file -e "$base^{commit}" 2>/dev/null || git fetch -q ${depth[@]+"${depth[@]}"} origin "$base"
trap 'git checkout HEAD -- src' EXIT
git checkout "$base" -- src
# Files this checkout added under src that the base does not have: gone for the base's run, back on exit.
git diff --name-only --relative --diff-filter=A "$base" HEAD -- src | while IFS= read -r file; do rm -f -- "$file"; done
run before

echo "=== PERF_ROW by run (label-mode name p50 p95)"
for log in "$out"/after-*.log "$out"/before-*.log; do
  [ -f "$log" ] || continue
  grep '^PERF_ROW ' "$log" | sed "s|^PERF_ROW |$(basename "$log" .log) |" || true
done
