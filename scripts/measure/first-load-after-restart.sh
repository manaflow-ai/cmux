#!/usr/bin/env bash
# A chat's first load after a restart (webviews/bench/first-load-after-restart.bench.ts) at several commits under
# this checkout's harness (bench-at-commits.sh), with the bench's knobs as arguments, so a fleet step needs no
# environment of its own:
#   cmux-ci run --class exclusive --key K --script scripts/measure/first-load-after-restart.sh --ref HEAD_SHA \
#     --arg BASE_SHA --arg HEAD_SHA --arg RUNNING=1 --arg CPU=6 --arg MODE=all
# Arguments that look like NAME=VALUE (RUNNING, CPU, ENGINE, MODE, ROUNDS, TURNS, ACPMUX_DOWN_MS, CONTENT,
# HEIGHT_DELTA, PAGES, TRACE, GATE)
# are the bench's environment; the rest are commits.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
shas=()
pairs=()
for arg in "$@"; do
  case "$arg" in
    RUNNING=* | CPU=* | ENGINE=* | MODE=* | ROUNDS=* | TURNS=* | ACPMUX_DOWN_MS=* | CONTENT=* | HEIGHT_DELTA=* | PAGES=* | TRACE=* | GATE=*) pairs+=("$arg") ;;
    *=*) echo "first-load-after-restart.sh: unknown knob $arg" >&2; exit 2 ;;
    *) shas+=("$arg") ;;
  esac
done
[[ ${#shas[@]} -gt 0 ]] || { echo "usage: first-load-after-restart.sh SHA... [KNOB=VALUE...]" >&2; exit 2; }
cd "$here/../../webviews" && { bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null 2>&1; }
ENV="$(IFS=,; echo "${pairs[*]-}")" exec "$here/bench-at-commits.sh" bench/first-load-after-restart.bench.ts ${shas[@]+"${shas[@]}"}
