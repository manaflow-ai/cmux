#!/usr/bin/env bash
# cmux-next.yml swift-test: "Run main-thread-heavy suites in their own process".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -uo pipefail
status=0
runs="$(python3 ../../../scripts/cmux-next/main-thread-heavy-suites.py Tests --targets "$SWIFT_TARGETS" --runs)" || exit 1
while read -r suite hang stuck; do
  [[ -n "$suite" ]] || continue
  echo "::group::$suite (run limit ${hang} s, stuck limit ${stuck} s)"
  if ! CMUX_NEXT_TEST_HANG_SECONDS="$hang" CMUX_NEXT_TEST_STUCK_SECONDS="$stuck" \
      ../../../scripts/cmux-next/swift-test-with-hang-sampler.sh --skip-build --no-parallel --filter "${suite//./\\.}\\b" < /dev/null; then
    status=1
    echo "::error title=main-thread-heavy suite red::$suite"
  fi
  echo "::endgroup::"
done <<< "$runs"
exit "$status"
