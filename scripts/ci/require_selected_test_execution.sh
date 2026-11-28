#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <xcodebuild-log> <test-filter>" >&2
  exit 2
fi

log_path="$1"
test_filter="$2"

if [[ -z "$test_filter" ]]; then
  exit 0
fi

if [[ ! -f "$log_path" ]]; then
  echo "selected test execution log is unavailable" >&2
  exit 2
fi

if grep -Eq \
  'XCTExpectFailure:[[:space:]]+matcher accepted Assertion Failure:[[:space:]]+Failed to activate application|Expected failure in .*:[[:space:]]+Failed to activate application' \
  "$log_path"; then
  echo "selected test recorded an app activation failure; refusing to treat the expected failure as a pass" >&2
  exit 1
fi

# An XCTest summary line belongs to the "Test Suite '<name>' passed|failed"
# line right before it. When the selected bundle (<target>.xctest) printed its
# own summary, judge that bundle's latest count rather than the largest count
# anywhere in the log, which may come from another bundle or an earlier run.
# Swift Testing prints no bundle line, so its run count still counts.
summary_count="$(
  SELECTED_BUNDLE="${test_filter%%/*}.xctest" awk '
    {
      if (match($0, /Test Suite '\''[^'\'']*'\'' (passed|failed) at/)) {
        suite = substr($0, RSTART + 12, RLENGTH - 12)
        sub(/'\'' (passed|failed) at$/, "", suite)
        next
      }
      if (match($0, /Executed [0-9]+ tests?/)) {
        summary = substr($0, RSTART, RLENGTH)
        sub(/^Executed /, "", summary)
        sub(/ tests?$/, "", summary)
        count = summary + 0
        if (!seen || count > max) max = count
        seen = 1
        if (suite == ENVIRON["SELECTED_BUNDLE"]) {
          bundle_count = count
          bundle_seen = 1
        }
      }
      if (match($0, /Test run with [0-9]+ tests?/)) {
        summary = substr($0, RSTART, RLENGTH)
        sub(/^Test run with /, "", summary)
        sub(/ tests?$/, "", summary)
        count = summary + 0
        if (!seen || count > max) max = count
        seen = 1
        if (!swift_seen || count > swift_max) swift_max = count
        swift_seen = 1
      }
      suite = ""
    }
    END {
      if (bundle_seen) {
        if (swift_seen && swift_max > bundle_count) bundle_count = swift_max
        print bundle_count
      } else if (seen) {
        print max
      }
    }
  ' "$log_path"
)"

if [[ -z "$summary_count" ]]; then
  echo "selected test execution summary was not found; verify the test log format" >&2
  exit 1
fi

if [[ "$summary_count" -eq 0 ]]; then
  printf 'selected test filter %q matched zero tests; use target/class or target/class/method syntax\n' "$test_filter" >&2
  exit 1
fi

printf '%s\n' "$summary_count"
