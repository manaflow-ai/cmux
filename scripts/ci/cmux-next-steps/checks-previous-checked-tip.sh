#!/usr/bin/env bash
# cmux-next.yml checks: "Previous checked tip".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
if [[ "$GITHUB_EVENT_NAME" == workflow_dispatch && "$BASE_TIER" == true ]]; then
  echo "event=push" >> "$GITHUB_OUTPUT"
  before="$(python3 -I scripts/ci/cmux_next_base_tier.py previous --tip "$GITHUB_SHA" || true)"
  echo "before=$before" >> "$GITHUB_OUTPUT"
  echo "base tier checks: commits ${before:-(none read)}..$GITHUB_SHA" >> "$GITHUB_STEP_SUMMARY"
fi
