#!/usr/bin/env bash
# cmux-next.yml checks: "Routing replay (router changes)".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
if [[ "$EVENT_NAME" != pull_request ]]; then
  echo "Pushes run every tier; the replay checks pull request routing only."
  exit 0
fi
if git diff --quiet HEAD^1 HEAD -- scripts/ci/cmux_next_route.py scripts/ci/select_package_tests.py; then
  echo "The router did not change."
  exit 0
fi
python3 scripts/ci/cmux_next_route_replay.py --base HEAD^1 --limit 30 | tee -a "$GITHUB_STEP_SUMMARY"
