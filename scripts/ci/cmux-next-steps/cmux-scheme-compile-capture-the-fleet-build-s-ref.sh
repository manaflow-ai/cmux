#!/usr/bin/env bash
# cmux-next.yml cmux-scheme-compile: "Capture the fleet build's REF".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
trap 'rm -rf -- "$SNAPSHOT"' EXIT
log="$(find "$CMUX_BUILD_METRICS_DIR" -maxdepth 1 -name 'xcodebuild-attempt-*.log' | sort -V | tail -1)"
python3 -I scripts/cmux-next/hybrid_ref_capture.py capture --log "$log" --workspace "$BUILD_ROOT" \
  --derived-data "$DERIVED_DATA" --read-workspace "$SNAPSHOT/src" --read-derived-data "$SNAPSHOT/dd" \
  --sha "$DEV_DAILY_SHA" --key "$KEY" --run-id "$GITHUB_RUN_ID" \
  --out "$RUNNER_TEMP/hybrid-ref-capture" --upload
