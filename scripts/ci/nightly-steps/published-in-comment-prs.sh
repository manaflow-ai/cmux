#!/usr/bin/env bash
# nightly.yml published-in: "Comment the build on its PRs". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
if [ "$PUBLISHED_SHA" = "$HEAD_SHA" ]; then echo "Empty span."; exit 0; fi
python3 scripts/ci/published_in_comments.py --repo "$GITHUB_REPOSITORY" \
  --since "$PUBLISHED_SHA" --head "$HEAD_SHA" \
  --name "cmux NEXT nightly $NIGHTLY_VERSION" \
  --url "https://github.com/$GITHUB_REPOSITORY/releases/tag/nightly-next"
