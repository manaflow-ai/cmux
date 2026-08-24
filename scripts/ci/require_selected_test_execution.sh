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
  echo "selected iOS test execution log is unavailable" >&2
  exit 2
fi

summary_kind="$(
  awk '
    /Executed [0-9]+ tests?,/ || /Test run with [0-9]+ tests? (passed|failed)/ {
      if ($0 ~ /Executed 0 tests?,/ || $0 ~ /Test run with 0 tests? (passed|failed)/) {
        zero = 1
      } else {
        positive = 1
      }
    }
    END {
      if (positive) print "positive"
      else if (zero) print "zero"
      else print "missing"
    }
  ' "$log_path"
)"

case "$summary_kind" in
  positive)
    exit 0
    ;;
  zero)
    echo "selected iOS test filter matched zero tests; use target/class or target/class/method syntax" >&2
    exit 1
    ;;
  *)
    echo "selected iOS test execution summary was not found; verify the test log format" >&2
    exit 1
    ;;
esac
