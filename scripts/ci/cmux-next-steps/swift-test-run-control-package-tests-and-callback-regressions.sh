#!/usr/bin/env bash
# cmux-next.yml swift-test: "Run control package tests and callback regressions".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -uo pipefail
status=0
../../../scripts/cmux-next/swift-test-with-hang-sampler.sh --skip-build --filter 'CmuxNextControlTests' \
  --skip CLISurfaceParityTests --skip "$MAIN_THREAD_HOLDERS" || status=$?
held=0
../../../scripts/cmux-next/swift-test-with-hang-sampler.sh --skip-build --no-parallel --filter "$MAIN_THREAD_HOLDERS" || held=$?
(( status == 0 && held == 0 ))
