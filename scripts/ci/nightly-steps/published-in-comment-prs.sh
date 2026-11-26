#!/usr/bin/env bash
# nightly.yml published-in: "Comment the build on its PRs". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
# SPAN_SINCE and PUBLISHED_AT come from published-in-fetch-span.sh; each PR's one status comment gets
# "Shipped in NIGHTLY <build> at <UTC time>", edited in place on a rerun.
set -euo pipefail
since="${SPAN_SINCE:-$PUBLISHED_SHA}"
if [ -z "$since" ] || [ "$since" = "$HEAD_SHA" ]; then echo "Empty span."; exit 0; fi
python3 scripts/ci/published_in_comments.py --repo "$GITHUB_REPOSITORY" \
  --since "$since" --head "$HEAD_SHA" \
  --name "NIGHTLY ${NIGHTLY_BUILD:-$NIGHTLY_VERSION}" --at "${PUBLISHED_AT:-}" \
  --url "https://github.com/$GITHUB_REPOSITORY/releases/tag/nightly-next"
