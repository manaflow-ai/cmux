#!/usr/bin/env bash
# Focused cmux-tui verification: run the Rust tests whose names contain FILTER, or fail.
# Usage (from cmux-tui/): ../scripts/ci/cmux-tui-focused-test.sh FILTER [libtest args...]
#
# cmux-tui.yml runs this in focused mode on Linux (`test`) AND on macOS (`macos`), so a
# filtered dispatch proves the filter on both hosts (cx-jcfoz: the macOS job ran only fixed
# groups and reported green without running the filter; a macOS-only regression landed).
# A filter that selects no test, or only ignored tests, fails loudly instead of passing.
# CMUX_TUI_FOCUSED_ALLOW_NONE_ON_HOST=1 (both jobs) lets a host with no matching test pass:
# host-only test files (#![cfg(target_os = "linux")], macOS-only tests) compile to nothing
# on the other host. With $GITHUB_OUTPUT set, the script writes `selected=N` (the runnable
# tests on this host); hosted verification fails the run when both hosts selected 0.
# Extra args go to the final libtest run (macOS passes --test-threads=2: process-heavy CLI
# tests exceed the smaller runner's child-process limit).
set -euo pipefail
filter="${1:?usage: cmux-tui-focused-test.sh FILTER [libtest args...]}"
shift
tmp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
if [[ "$filter" == "chatmux_relay" || "$filter" == "chatmux-relay" ]]; then
  # Cargo test names do not include their package name. Keep this explicit selector so
  # focused verification can exercise the relay crate instead of silently selecting zero tests.
  cargo test -p chatmux-relay --locked -- "$@"
  exit 0
fi
# Build first: a cold compile can be quiet for minutes, a listing never is. Each test binary
# lists in seconds, so a listing quiet for 3 minutes is a hung binary: the watchdog names it
# (its last line is cargo's `Running ... (target/debug/deps/NAME)`), samples its stack on
# macOS and ends it. Before, a cmux_tui binary that hung while listing ran into the job's
# 40 minute timeout with only "The operation was canceled." (2026-11-08: 2 of 13 macOS
# jobs, runs 42458823348 and 42461695724; the second job queued on that host waited for it).
cargo test --workspace --locked --no-run "$filter"
watchdog="$(cd "$(dirname "$0")" && pwd)/hung_test_watchdog.py"
list_tests() {
  python3 "$watchdog" --silence-seconds "${CMUX_TUI_FOCUSED_LIST_SILENCE_SECONDS:-180}" \
    --label "cmux-tui test listing" -- cargo test --workspace --locked "$filter" -- --list "$@"
}
list_tests | tee "$tmp/cmux-tui-focused-tests.txt"
normal_names="$tmp/cmux-tui-focused-normal.txt"
grep -E ': test$' "$tmp/cmux-tui-focused-tests.txt" | sort > "$normal_names" || true
ignored_names="$tmp/cmux-tui-focused-ignored.txt"
ignored_listing="$tmp/cmux-tui-focused-ignored-list.txt"
# The ignored pass goes to a file, so a hang or a cargo failure there prints what it captured
# (the watchdog's error, the binary it named and its stack) before failing.
status=0
list_tests --ignored > "$ignored_listing" || status=$?
if (( status != 0 )); then
  cat "$ignored_listing"
  exit "$status"
fi
grep -E ': test$' "$ignored_listing" | sort > "$ignored_names" || [[ "$?" -eq 1 ]]
runnable_names="$tmp/cmux-tui-focused-runnable.txt"
comm -23 "$normal_names" "$ignored_names" > "$runnable_names" || true
if [[ ! -s "$runnable_names" && -s "$ignored_names" ]]; then
  echo "::error::test_filter '$filter' matches only ignored tests" >&2
  exit 1
fi
selected="$(grep -c . "$runnable_names" || true)"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "selected=${selected:-0}" >> "$GITHUB_OUTPUT"
fi
if [[ ! -s "$normal_names" ]]; then
  if [[ "${CMUX_TUI_FOCUSED_ALLOW_NONE_ON_HOST:-}" == "1" ]]; then
    echo "::notice::test_filter '$filter' selects no Rust test on this host; hosted verification fails the run only if the other host selects none too"
    exit 0
  fi
  echo "::error::test_filter '$filter' selected no Rust tests" >&2
  exit 1
fi
cargo test --workspace --locked --no-fail-fast "$filter" -- "$@"
