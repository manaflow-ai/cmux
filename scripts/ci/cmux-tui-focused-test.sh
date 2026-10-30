#!/usr/bin/env bash
# Focused cmux-tui verification: run the Rust tests whose names contain FILTER, or fail.
# Usage (from cmux-tui/): ../scripts/ci/cmux-tui-focused-test.sh FILTER [libtest args...]
#
# cmux-tui.yml runs this in focused mode on Linux (`test`) AND on macOS (`macos`), so a
# filtered dispatch proves the filter on both hosts (cx-jcfoz: the macOS job ran only fixed
# groups and reported green without running the filter; a macOS-only regression landed).
# A filter that selects no test, or only ignored tests, fails loudly instead of passing.
# CMUX_TUI_FOCUSED_ALLOW_NONE_ON_HOST=1 (the macOS job) lets a host with no matching test
# pass: Linux-only test files (#![cfg(target_os = "linux")]) compile to nothing there, and
# the strict Linux run still fails a filter that matches nothing anywhere.
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
cargo test --workspace --locked "$filter" -- --list \
  | tee "$tmp/cmux-tui-focused-tests.txt"
normal_names="$tmp/cmux-tui-focused-normal.txt"
grep -E ': test$' "$tmp/cmux-tui-focused-tests.txt" | sort > "$normal_names" || true
ignored_names="$tmp/cmux-tui-focused-ignored.txt"
ignored_listing="$tmp/cmux-tui-focused-ignored-list.txt"
cargo test --workspace --locked "$filter" -- --list --ignored > "$ignored_listing"
grep -E ': test$' "$ignored_listing" | sort > "$ignored_names" || [[ "$?" -eq 1 ]]
runnable_names="$tmp/cmux-tui-focused-runnable.txt"
comm -23 "$normal_names" "$ignored_names" > "$runnable_names" || true
if [[ ! -s "$runnable_names" && -s "$ignored_names" ]]; then
  echo "::error::test_filter '$filter' matches only ignored tests" >&2
  exit 1
fi
if [[ ! -s "$normal_names" ]]; then
  if [[ "${CMUX_TUI_FOCUSED_ALLOW_NONE_ON_HOST:-}" == "1" ]]; then
    echo "::notice::test_filter '$filter' selects no Rust test on this host; the Linux job runs it"
    exit 0
  fi
  echo "::error::test_filter '$filter' selected no Rust tests" >&2
  exit 1
fi
cargo test --workspace --locked --no-fail-fast "$filter" -- "$@"
