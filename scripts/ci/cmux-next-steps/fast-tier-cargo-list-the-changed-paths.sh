#!/usr/bin/env bash
# cmux-next.yml fast-tier-cargo: "List the changed paths".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
if git rev-parse -q --verify 'HEAD^2' >/dev/null; then
  git diff --name-only --no-renames -z 'HEAD^1' HEAD > "$RUNNER_TEMP/changed-paths.txt"
  echo "PATHS_FILE=$RUNNER_TEMP/changed-paths.txt" >> "$GITHUB_ENV"
  echo "FAST_TIER_SCOPE_KEY=pr-diff-$(sha256sum "$RUNNER_TEMP/changed-paths.txt" | cut -c1-16)" >> "$GITHUB_ENV"
else
  echo "::notice::No merge commit to diff: every fast tier entry runs."
fi
