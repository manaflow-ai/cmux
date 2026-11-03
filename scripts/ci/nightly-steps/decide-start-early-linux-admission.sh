#!/usr/bin/env bash
# nightly.yml decide: "Start early Linux admission beside the Mac picker". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
[ "$CHECK_RECEIPTS" = 1 ] && exit 0
state="$RUNNER_TEMP/early-linux-admission"
( set +e
  GITHUB_OUTPUT="$state.out" GITHUB_STEP_SUMMARY="$state.summary" \
    python3 scripts/ci/nightly_linux_admission.py > "$state.log" 2>&1
  echo $? > "$state.rc" ) > /dev/null 2>&1 &
echo $! > "$state.pid"
