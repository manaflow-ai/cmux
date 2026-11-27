#!/usr/bin/env bash
# cmux-next.yml swift-test: "Find the main-thread-heavy suites".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
heavy="$(python3 scripts/cmux-next/main-thread-heavy-suites.py Packages/macOS/CmuxNext/Tests --targets "$SWIFT_TARGETS")"
echo "CMUX_NEXT_MAIN_THREAD_HEAVY=$heavy" >> "$GITHUB_ENV"
suites="$(python3 scripts/cmux-next/main-thread-heavy-suites.py Packages/macOS/CmuxNext/Tests --targets "$SWIFT_TARGETS" --list)"
echo "CMUX_NEXT_MAIN_THREAD_HEAVY_SUITES=${suites//$'\n'/ }" >> "$GITHUB_ENV"
while read -r suite; do [[ -z "$suite" ]] || echo "main-thread heavy: $suite"; done <<< "$suites"
