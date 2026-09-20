#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <package-path>" >&2
  exit 2
fi

package_path="$1"
suite_timeout_seconds="${CMUX_SWIFT_TEST_SUITE_TIMEOUT_SECONDS:-300}"
if ! [[ "$suite_timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "CMUX_SWIFT_TEST_SUITE_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
suite_log="$(mktemp "${TMPDIR:-/tmp}/cmux-swift-suites.XXXXXX")"
trap 'rm -f "$suite_log"' EXIT
ghostty_diagnostic='^error: unexpected binary name at /.*/GhosttyKit[.]xcframework/macos-arm64_x86_64/ghostty-internal[.]a[.] Static libraries should be prefixed with lib$'

is_cosmetic_ghostty_failure() {
  [ "$1" -eq 1 ] && [ "$(basename "${package_path%/}")" = CmuxTerminal ] || return 1
  # Read the whole log: an early-exiting grep in a pipe can turn a real
  # error into a SIGPIPE status and accidentally make a negated guard pass.
  awk -v known="$ghostty_diagnostic" '
    $0 ~ known { found = 1; next }
    /(^|[^a-zA-Z])error:/ { other_error = 1 }
    /Segmentation fault|Abort trap|Bus error|Illegal instruction/ { other_error = 1 }
    END { exit !(found && !other_error) }
  ' "$suite_log"
}

has_passing_test_summary() {
  awk '
    /Test run with [1-9][0-9]* tests?( in [1-9][0-9]* suites?)? passed after/ { swift_passed = 1 }
    /Test Suite .Selected tests. passed at/ { xctest_complete = 1 }
    /Executed [1-9][0-9]* tests?, with 0 failures/ { xctest_passed = 1 }
    /^✘|with [1-9][0-9]* (failures?|issues?)|Test Suite .* failed at/ { failed = 1 }
    /Segmentation fault|Abort trap|Bus error|Illegal instruction/ { failed = 1 }
    END { exit !(!failed && (swift_passed || (xctest_passed && xctest_complete))) }
  ' "$suite_log"
}

run_suite() {
  suite_status=0
  # Keep live CI output without holding an entire suite in shell memory, and
  # prevent the child from consuming the suite-list input that drives the loop.
  if python3 "$script_dir/run_with_timeout.py" \
    --timeout-seconds "$suite_timeout_seconds" \
    -- swift test --package-path "$package_path" --filter "$suite" \
    < /dev/null 2>&1 | tee "$suite_log"; then
    return
  else
    local pipeline_status=("${PIPESTATUS[@]}")
    # A logging failure must never be mistaken for SwiftPM's cosmetic exit 1.
    if [ "${pipeline_status[1]}" -ne 0 ]; then
      exit "${pipeline_status[1]}"
    fi
    suite_status="${pipeline_status[0]}"
  fi
}

# Keep process-global test state inside one suite. Some packages otherwise
# finish every assertion but leave the aggregate Swift Testing runner waiting.
# GhosttyKit's static archive name also makes `swift test list` return a
# nonzero status after emitting the complete list. Preserve that list while
# tolerating only the same known diagnostic accepted by the package test lane.
suite_list_status=0
swift test list --package-path "$package_path" > "$suite_log" 2>&1 || suite_list_status=$?
if [ "$suite_list_status" -ne 0 ]; then
  if ! is_cosmetic_ghostty_failure "$suite_list_status"; then
    cat "$suite_log" >&2
    exit "$suite_list_status"
  fi
fi
suite_list="$(sed -nE 's/^[A-Za-z_][A-Za-z0-9_]*\.([A-Za-z_][A-Za-z0-9_]*)\/.+$/\1/p' "$suite_log" | sort -u)"

if [ -z "$suite_list" ]; then
  echo "no test suites discovered for $package_path" >&2
  exit 1
fi

while IFS= read -r suite; do
  [ -n "$suite" ] || continue
  echo "swift test $package_path --filter $suite"
  run_suite
  if [ "$suite_status" -eq 124 ]; then
    echo "Swift test suite timed out; retrying $suite once." >&2
    run_suite
  fi
  if [ "$suite_status" -ne 0 ] && ! is_cosmetic_ghostty_failure "$suite_status"; then
    exit "$suite_status"
  fi
  if ! has_passing_test_summary; then
    echo "No complete, nonzero passing test run for $suite in $package_path." >&2
    exit 1
  fi
  if [ "$suite_status" -ne 0 ]; then
    echo "Tolerated cosmetic GhosttyKit binaryTarget diagnostic; all tests passed."
  fi
done < <(printf '%s\n' "$suite_list")
