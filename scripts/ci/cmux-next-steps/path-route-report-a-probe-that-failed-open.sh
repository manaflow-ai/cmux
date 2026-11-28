#!/usr/bin/env bash
# cmux-next.yml path_route: "Report a probe that failed open".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
reason="the same-tree cmux-tui probe failed or passed its 2-minute limit (first probe: $FIRST, after the marker: ${FINAL:-not run}); the routed compile and test jobs still run, and the tree jobs run only on a tree_state the probe wrote"
echo "::warning title=same-tree cmux-tui probe failed open::$reason"
{ echo '### same-tree cmux-tui probe failed open'; echo; echo "$reason"; } >> "$GITHUB_STEP_SUMMARY"
