#!/usr/bin/env bash
# nightly.yml resolve-nightly-cmux-tui-client: "Leave the build slot to a newer nightly-next push". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
current="$(gh api "repos/$REPOSITORY/git/ref/heads/nightly-next" --jq .object.sha)"
if [[ "$current" =~ ^[0-9a-f]{40}$ && "$current" != "$TIP_SHA" ]]; then
  echo "superseded=true" >> "$GITHUB_OUTPUT"
  echo "::notice title=Superseded::nightly-next moved from $TIP_SHA to $current; the newer push's run builds it"
else
  echo "superseded=false" >> "$GITHUB_OUTPUT"
fi
