#!/usr/bin/env bash
# nightly.yml pick-nightly-build-runner: "Write the owned-pool watch marker". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
marker="$RUNNER_TEMP/owned-pool-watch/nightly-build-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
mkdir -p "${marker%/*}"
printf '%s\n' "$OWNED" > "$marker"
echo "path=$marker" >> "$GITHUB_OUTPUT"
