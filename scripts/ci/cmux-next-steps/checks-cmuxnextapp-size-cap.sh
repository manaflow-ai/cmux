#!/usr/bin/env bash
# cmux-next.yml checks: "CmuxNextApp size cap".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
if [[ "$FULL_CI" != true ]]; then
  echo "Size cap is a batch cadence check; ordinary PRs receive the fast tier only."
  exit 0
fi
base=()
[[ "$EVENT_NAME" == pull_request ]] && base=(--base HEAD^1)
if [[ "$EVENT_NAME" == push && -n "$BEFORE" && "$BEFORE" != 0000000000000000000000000000000000000000 ]]; then
  depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
  git cat-file -e "$BEFORE^{commit}" 2>/dev/null \
    || git fetch --no-tags --quiet ${depth[@]+"${depth[@]}"} origin "$BEFORE" || true
  base=(--base "$BEFORE")
fi
scripts/cmux-next/check-app-size.sh ${base[@]+"${base[@]}"} "$GITHUB_WORKSPACE"
