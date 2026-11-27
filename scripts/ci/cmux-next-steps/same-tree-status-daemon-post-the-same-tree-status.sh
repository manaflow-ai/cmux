#!/usr/bin/env bash
# cmux-next.yml same-tree-status-daemon: "Post the same-tree status".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
dev=()
[[ "$DEV_DAILY" == true ]] && dev=(--dev-daily)
python3 -I scripts/ci/cmux_next_same_tree_status.py --tier daemon --repo "$GITHUB_REPOSITORY" \
  --status-sha "$STATUS_SHA" --state "$STATE" --needs "$NEEDS" --reason "$REASON" \
  --run-id "$GITHUB_RUN_ID" --attempt "$GITHUB_RUN_ATTEMPT" ${dev[@]+"${dev[@]}"}
