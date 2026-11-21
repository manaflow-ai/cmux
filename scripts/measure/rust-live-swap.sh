#!/usr/bin/env bash
# cmux live --rust, measured end to end on this host: a scratch daemon with three shells, then
# one-line edits to cmux-tui-core (a field in `identify`), each timed from the save to the swapped
# daemon answering with the edit, with every shell checked to be the same process, with its
# screen, still echoing. The edit is always taken back. Report: OUT/result.json (p50/p95).
#   scripts/measure/rust-live-swap.sh OUT [--runs N] [--build-host HOST]
set -euo pipefail
out="${1:?usage: rust-live-swap.sh OUT [rust-live.py measure flags]}"
shift
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$out"
code=0
python3 "$root/scripts/cmux-next/rust-live.py" measure --worktree "$root" --out "$out" "$@" \
  2> >(tee "$out/measure.log" >&2) || code=$?
# A fleet step (cmux-ci run --artifact) brings back what is in $FAST_CHECKS_OUT.
if [[ -n "${FAST_CHECKS_OUT:-}" && "$out" != "$FAST_CHECKS_OUT" ]]; then
  mkdir -p "$FAST_CHECKS_OUT" && cp -R "$out/." "$FAST_CHECKS_OUT/"
fi
exit "$code"
