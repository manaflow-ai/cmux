#!/usr/bin/env bash
# compile-rate-bench.sh refuses a bad argument and a run off the fleet (exit 2) before it builds anything.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/compile-rate-bench.sh"

refuses() {
  local want="$1" err status
  shift
  set +e
  err="$(env -u CMUX_CI_STEP_KEY -u GITHUB_ACTIONS bash "$script" "$@" 2>&1 >/dev/null)"
  status=$?
  set -e
  [[ "$status" == 2 ]] || { echo "compile-rate-bench $*: exit $status, want 2 ($err)" >&2; exit 1; }
  [[ "$err" == *"$want"* ]] || { echo "compile-rate-bench $*: said '$err', want '$want'" >&2; exit 1; }
}

refuses "runs must be 1-9" runs=0
refuses "runs must be 1-9" runs=10
refuses "crate must be a cmux-tui package name" "crate=a b"
refuses "unknown argument 'jobs=4'" jobs=4
refuses "runs only on the build fleet" runs=1 crate=acpmux
echo "ok: compile-rate-bench.sh refuses bad arguments and off-fleet runs"
