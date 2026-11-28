#!/usr/bin/env bash
# RUSTC_WRAPPER that lets only one of the workspace's memory-heaviest crates compile at a time; every other crate
# runs rustc directly. On cloud-journey-pr.yml's 14 GiB runner the acpmux rustc (over 10.6 GB at opt-level 0, with
# line tables or with no debuginfo) and the cmux-tui-core rustc (5.3 GB) overlapped and the kernel SIGKILLed acpmux
# (PR run 46147374990 at 4 jobs, base seed 46157101135). Measured on 2026-11-28 with a peak-RSS wrapper around rustc.
# Capping CARGO_BUILD_JOBS can't separate two crates that both start once their dependencies are done; this lock
# can, and it leaves features, flags and outputs as they were, so the R2 key and fingerprints don't change.
# RUSTC_HEAVY_CRATES (space separated crate names) overrides the list.
# Why: docs/ci/cmux-next-workflow-notes.md#note-cloud-journey-pr-wall
set -euo pipefail
rustc="$1"
shift
heavy=" ${RUSTC_HEAVY_CRATES:-acpmux cmux_tui_core} "
crate=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--crate-name" ]; then crate="$arg"; break; fi
  prev="$arg"
done
if [ -n "$crate" ] && [[ "$heavy" == *" $crate "* ]] && command -v flock >/dev/null 2>&1; then
  lock="${RUSTC_HEAVY_LOCK:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/rustc-heavy.lock}"
  exec flock "$lock" "$rustc" "$@"
fi
exec "$rustc" "$@"
