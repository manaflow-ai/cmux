#!/usr/bin/env bash
# nightly.yml decide: "Admit early controls on reserved fleet Linux". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# The controller reserves unconsumed JIT runners before placement.
# Opted-in builds require the controller App receipt before choosing any runner.
# Disabled builds retain the existing private-controller/declared-light fallback.
set -uo pipefail
state="$RUNNER_TEMP/early-linux-admission"
if [ ! -s "$state.pid" ]; then
  python3 scripts/ci/nightly_linux_admission.py
  exit $?
fi
tail --pid="$(cat "$state.pid")" -f /dev/null
cat "$state.log"
cat "$state.out" >> "$GITHUB_OUTPUT"
cat "$state.summary" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
exit "$(cat "$state.rc" 2>/dev/null || echo 1)"
