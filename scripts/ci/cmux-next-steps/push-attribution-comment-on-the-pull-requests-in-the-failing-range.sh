#!/usr/bin/env bash
# cmux-next.yml push-attribution: "Comment on the pull requests in the failing range".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
python3 scripts/ci/cmux_next_push_attribution.py --repo "$GITHUB_REPOSITORY" \
  --run-id "$GITHUB_RUN_ID" --sha "$SHA" --server-url "$GITHUB_SERVER_URL" \
  --events push,workflow_dispatch --summary "$GITHUB_STEP_SUMMARY" \
  --last-known-green "$(git ls-remote --heads origin refs/heads/last-known-green | awk '{print $1}')"
