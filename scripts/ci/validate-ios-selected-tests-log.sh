#!/usr/bin/env bash
set -euo pipefail

log_path="${1:-}"
if [[ -z "$log_path" || ! -f "$log_path" ]]; then
  printf 'validate-ios-selected-tests-log: test log not found: %s\n' "${log_path:-<empty>}" >&2
  exit 2
fi

if ! grep -Eq "Test Suite 'Selected tests' passed|Test Suite 'cmuxUITests' passed" "$log_path"; then
  printf 'validate-ios-selected-tests-log: selected XCTest suite did not pass\n' >&2
  exit 1
fi

if ! grep -Eq "Executed [1-9][0-9]* tests?, with 0 failures \\(0 unexpected\\)" "$log_path"; then
  printf 'validate-ios-selected-tests-log: selected filter executed no passing tests\n' >&2
  exit 1
fi

if grep -Eq "Test Suite '.*' failed|Test Case '.*' failed|Assertion Failure|Failing tests:|with [1-9][0-9]* failures?|with [0-9]+ failures? \\([1-9][0-9]* unexpected\\)|✘ Test|✘ Suite" "$log_path"; then
  printf 'validate-ios-selected-tests-log: selected test log contains a failure\n' >&2
  exit 1
fi

printf 'validate-ios-selected-tests-log: selected tests passed\n'
