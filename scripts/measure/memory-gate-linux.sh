#!/usr/bin/env bash
# Per-PR memory check, no Mac: does this head grow what a hibernated item costs in acpmux + cmux-tui?
#
# Leo, 2026-11-22 (ask-5b56389121): "i also want us to keep pursuing the ability to have infinite f***ing tabs and
# workspaces and s*** without getting starved of cpu/ram". The Mac bench (infinite-tabs.sh) needs the exclusive
# class (it launches the app) and waits about 17 h at p90; this runs on any Linux runner in about 20 minutes.
#
#   memory-gate-linux.sh [base=REF] [repeat=3] [counts=100] [days=1] [tolerance=0.10] [floor_mb=0.05]
#
# base defaults to the merge base with origin/feat-cmux-next (GITHUB_BASE_SHA when CI sets it). It builds both
# with no LTO into a target folder of its own (infinite-items-linux.sh before=ref: builds the base incrementally
# over the head in that folder), runs them interleaved `repeat` times on this runner, and has memory_gate.py judge
# infinite_items.n<count>.mb_per_item. Exit 0 flat, 1 grew, 2 harness failed. To find which landing grew it:
# memory_bisect.py --good BASE --bad HEAD.
set -uo pipefail
base="" repeat=3 counts=100 days=1 tolerance=0.10 floor_mb=0.05
for arg in "$@"; do
  case "$arg" in
    base=*) base="${arg#base=}" ;;
    repeat=*) repeat="${arg#repeat=}" ;;
    counts=*) counts="${arg#counts=}" ;;
    days=*) days="${arg#days=}" ;;
    tolerance=*) tolerance="${arg#tolerance=}" ;;
    floor_mb=*) floor_mb="${arg#floor_mb=}" ;;
    *) echo "memory-gate-linux.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
if [ -z "$base" ]; then
  if [ -n "${GITHUB_BASE_SHA:-}" ]; then
    git cat-file -e "$GITHUB_BASE_SHA^{commit}" 2>/dev/null || git fetch -q origin "$GITHUB_BASE_SHA" || true
    base="$(git merge-base "$GITHUB_BASE_SHA" HEAD 2>/dev/null || echo "$GITHUB_BASE_SHA")"
  else
    git fetch -q origin feat-cmux-next 2>/dev/null || true
    base="$(git merge-base origin/feat-cmux-next HEAD 2>/dev/null || true)"
  fi
fi
[ -n "$base" ] || { echo "memory-gate-linux.sh: no base (pass base=REF)" >&2; exit 2; }
export CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 CARGO_INCREMENTAL=0
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${RUNNER_TEMP:-/tmp}/memory-gate-target}"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
echo "MEMORY_GATE base=$base head=$(git rev-parse HEAD) repeat=$repeat counts=$counts days=$days"
harness=0
scripts/measure/infinite-items-linux.sh "before=ref:$base" "repeat=$repeat" "counts=$counts" "days=$days" pages=0 \
  2>&1 | tee "$log" || harness=$?
metric="infinite_items.n*.mb_per_item"
python3 scripts/measure/memory_gate.py verdict "$log" --metric "$metric" --tolerance "$tolerance" \
  --floor-mb "$floor_mb" --markdown | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
rc=${PIPESTATUS[0]}
if [ "$rc" = 1 ]; then
  echo "memory-gate-linux.sh: an item costs more after this change; find the commit with" \
    "python3 scripts/measure/memory_bisect.py --good $base --bad HEAD" >&2
fi
[ "$rc" = 2 ] && [ "$harness" != 0 ] && echo "memory-gate-linux.sh: the harness failed ($harness)" >&2
exit "$rc"
