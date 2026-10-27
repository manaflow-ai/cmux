#!/usr/bin/env bash
# Builder story incremental-build (scripts/perf-lab/stories.d/incremental-build.json): the edit loop's rebuild after
# a one-line leaf edit, timed per leaf, with the rebuilt-module list and the slow type-check queue (MQ15).
#   cmux-ci run --class exclusive --script scripts/measure/incremental-build.sh --ref <sha> \
#     --artifact artifacts/incremental-build [--arg=--rounds=3] [--arg=--leaf=app_handler]
#
# Runs on a builder, never on a perf-lab host (worker label perf-lab or a host in scripts/perf-lab/pool.json): the
# story refuses there before it builds anything. It prepares what `swift build` of the CmuxNext package and
# `cargo build -p cmux-tui` need at this checkout (the web bundles the package ships as resources, the ghostty-next
# submodule the vt crates build from), then runs scripts/perf-lab/stories/incremental_build.py, which does the warm
# builds, the edits, the timed rebuilds and the restores (its docstring has the details).
#
# Every leaf the story edits is put back on exit, TERM, INT and HUP: by the story itself, and again here
# (`incremental_build.py restore` touches only a leaf that holds HEAD's bytes plus probe lines). The story runs as a
# background job this script waits for, because bash runs a trap only after its foreground child exits: a signal to
# this script is passed on to the story at once, which stops its build and restores, and then the trap restores too.
# Output in artifacts/incremental-build (or the runner's --out): one result-v1 file, rebuilt-modules.json,
# incremental-diagnostics.json, typecheck-queue.json, and builds/ with each build's receipt and log.
# Exit: 0 every leaf measured every round; 1 some rebuild failed (the rest are written); 2 refused or nothing measured.
set -euo pipefail
# swift build and cargo build: fleet or GitHub runner only.
# shellcheck source=scripts/cmux-next/lib/fleet-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/../cmux-next/lib/fleet-only.sh"
cmux_next_require_fleet incremental-build.sh "swift build and cargo build" "perf lab builder story incremental-build" \
  "cmux-ci run --class exclusive --script scripts/measure/incremental-build.sh --ref SHA"
cd "$(git rev-parse --show-toplevel)"
story=(python3 -I scripts/perf-lab/stories/incremental_build.py)
"${story[@]}" check-host

story_pid=""
restore() {
  "${story[@]}" restore || echo "incremental-build: the restore did not run; check the leaves with git status" >&2
}
on_signal() {
  trap - EXIT
  if [[ -n "$story_pid" ]]; then
    kill -TERM "$story_pid" 2>/dev/null || true
    wait "$story_pid" || true
  fi
  restore
  exit "$1"
}
trap restore EXIT
trap 'on_signal 143' TERM
trap 'on_signal 130' INT
trap 'on_signal 129' HUP

out="$PWD/artifacts/incremental-build"
rm -rf "$out"
mkdir -p "$out"

# Always: on a reused checkout moved to a new --ref, the submodule must move to this commit's pin (a no-op when it is).
if ! git submodule update --init --depth 1 ghostty-next; then
  echo "incremental-build: ghostty-next could not be checked out at this commit's pin; cmux-tui would build other sources" >&2
  exit 2
fi
scripts/cmux-next/build-web-bundles.sh

# The runner's own --out (stories.d/README.md) comes later in "$@" and wins.
"${story[@]}" run --out "$out" "$@" &
story_pid=$!
status=0
wait "$story_pid" || status=$?
story_pid=""
exit "$status"
