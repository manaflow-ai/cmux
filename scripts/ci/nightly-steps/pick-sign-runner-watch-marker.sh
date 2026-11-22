#!/usr/bin/env bash
# nightly.yml pick-nightly-sign-runner: "Write the owned-pool watch marker". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# As pick-nightly-build-runner: a dispatch made with GITHUB_TOKEN, or a re-run, may start no
# workflow_run event, so an owned pick there leaves the sweeper's owned-pool-watch marker.
marker="$RUNNER_TEMP/owned-pool-watch/nightly-verify-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
mkdir -p "${marker%/*}"
printf '%s\n' "$OWNED" > "$marker"
echo "path=$marker" >> "$GITHUB_OUTPUT"
