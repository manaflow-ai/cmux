#!/usr/bin/env bash
# nightly.yml visual-gate-nightly: "Capture the states". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# exec: the runner signals the step's shell on cancel; capture_states.py
# then stops the app and its daemon itself. Exit 1 only means a state
# had a failed step, which the gate reports.
set -e  # the inline step ran under bash -e
rm -rf "$RUNNER_TEMP/visual-gate"
exec python3 scripts/cmux-next/visual-gate/capture_states.py --app "$APP" \
  --out "$RUNNER_TEMP/visual-gate" scripts/cmux-next/visual-gate/states
