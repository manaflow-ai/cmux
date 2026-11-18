#!/usr/bin/env bash
# Run `cargo test <args>` with a per-test deadline (scripts/ci/test_deadline.py).
#
# usage: scripts/ci/cargo-test-deadline.sh <cargo test args...>
#   e.g. ../scripts/ci/cargo-test-deadline.sh -p cmux-tui-core --lib -- --test-threads=2
#
# libtest has no per-test time limit, so one hung test held a hosted cmux-tui
# job until the job timeout and the run read as "cancelled" with no test named
# (runs 42712581504, 42687069230, 2026-11-09). Through this wrapper the run
# ends when one test runs past CMUX_TEST_DEADLINE_SECONDS (default 180, as the
# app::tests guard of #39954) and the error names the test.
# CMUX_TEST_DEADLINE_SLOW holds space-separated NAME=SECONDS overrides for tests
# that must run longer. The cargo exit status is kept otherwise, and the output
# is not changed.
#
# This is the one place hosted workflows run cargo test through. A move to
# cargo-nextest (its slow-timeout gives the same deadline natively) replaces
# the command below and nothing in the workflows.
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "usage: cargo-test-deadline.sh <cargo test args...>" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python=""
# A Windows runner can list a python3 that only opens the Store: use the first that runs.
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    python=$candidate
    break
  fi
done
if [[ -z "$python" ]]; then
  echo "::warning::cargo-test-deadline.sh: no python3 on this runner; running cargo test without a per-test deadline" >&2
  exec cargo test "$@"
fi

# test_deadline.py reads CMUX_TEST_DEADLINE_SECONDS and CMUX_TEST_DEADLINE_SLOW itself.
exec "$python" "$script_dir/test_deadline.py" -- cargo test "$@"
