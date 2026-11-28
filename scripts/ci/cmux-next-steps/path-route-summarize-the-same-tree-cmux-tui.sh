#!/usr/bin/env bash
# cmux-next.yml path_route: "Summarize the same-tree cmux-tui".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
if [[ "$EVENT_NAME" == pull_request && "$STATE" == failed ]]; then
  STATE=skipped
  REASON="No cmux-tui-pin ref is created for pull requests; re-run after a trusted feat-cmux-next publication. $REASON"
fi
{
  echo "### same-tree cmux-tui $KEY: $STATE"
  echo
  echo "$REASON"
} >> "$GITHUB_STEP_SUMMARY"
if [[ "$STATE" == skipped ]]; then
  echo "::notice title=same-tree cmux-tui skipped::$REASON"
elif [[ "$STATE" == deferred ]]; then
  echo "::notice title=same-tree cmux-tui deferred::$REASON"
fi
