#!/usr/bin/env bash
# nightly.yml retry-nightly-next: "Ask the push group for the newest head". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the job's env: sets every input. The retry builds the head; a stale
# retry waits in resolve-leave-build-slot.sh for the tick to promote a newer buildable commit, and leaves to it.
set -euo pipefail
tries=$(( ${RETRY:-0} + 1 ))
if [ "$tries" -gt 2 ]; then
  echo "::warning::nightly-next failed after two retries in a row; the next push starts the loop again"
  exit 0
fi
head=$(gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/nightly-next" --jq .object.sha)
if [ "$head" != "$SHA" ]; then
  echo "nightly-next moved to $head: its push run takes the group's pending place, so no retry"
  exit 0
fi
echo "retry $tries of 2 after run $RUN_ID attempt $RUN_ATTEMPT: build the nightly-next head again"
gh workflow run nightly.yml --repo "$GITHUB_REPOSITORY" --ref nightly-next -f nightly_next_loop_retry="$tries"
