#!/usr/bin/env bash
# Run `cargo test <args>` for a hand-picked test selection in CI, and fail when
# the selection ran no test.
#
# usage: scripts/ci/cargo-test-selected.sh <cargo test args...>
#   e.g. scripts/ci/cargo-test-selected.sh -p cmux-tui-platform --lib platform::tests:: -- --test-threads=2
#
# libtest exits 0 when a name filter matches nothing ("0 passed; ... N filtered
# out"), so a selector left behind by a move (a test that changed crate or
# module) turns into a green step that runs nothing. After the platform crate
# split (f8e3500ec0df) four macOS cmux-tui.yml steps did exactly that. This
# wrapper sums the "test result:" lines of every test binary and exits 1 when
# no test passed or failed (ignored tests do not count: they did not run).
# A failing cargo run keeps its own exit status. Output is not filtered.
# Test: scripts/cmux-next/tests/cargo-test-selected.test.sh.
set -euo pipefail

if [[ $# -eq 0 || "$1" == "--" ]]; then
  echo "usage: cargo-test-selected.sh <cargo test args...> (a test selection is required)" >&2
  exit 2
fi

log=$(mktemp)
trap 'rm -f "$log"' EXIT

status=0
cargo test "$@" | tee "$log" || status=$?
if [[ $status -ne 0 ]]; then
  exit "$status"
fi

ran=$(awk '/^test result: /{
  for (i = 1; i <= NF; i++) {
    if ($(i+1) ~ /^passed;?$/ || $(i+1) ~ /^failed;?$/) n += $i
  }
} END { print n + 0 }' "$log")

if [[ "$ran" -eq 0 ]]; then
  echo "::error::cargo test $* ran no test: the selection matches no test (moved or renamed?). Point it at the test's current crate and path." >&2
  exit 1
fi
echo "cargo-test-selected: $ran test(s) ran for: cargo test $*"
