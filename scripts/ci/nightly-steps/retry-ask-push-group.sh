#!/usr/bin/env bash
# nightly.yml retry-nightly-next: "Ask the push group for the newest head". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the job's env: sets every input. The retry builds the head; a stale
# retry waits in resolve-leave-build-slot.sh for the tick to promote a newer buildable commit, and leaves to it.
set -euo pipefail
tries=$(( ${RETRY:-0} + 1 ))
if [ "$tries" -gt 2 ]; then
  # The owner hears it: a comment on the nightly-next-feed-stale issue with the head, the failing step and its
  # error line, not only a warning nobody reads (2026-11-18/19: the feed went 24 h stale behind four such runs).
  echo "::warning::nightly-next failed after two retries in a row; the next push starts the loop again"
  python3 "$(dirname "${BASH_SOURCE[0]}")/../nightly_next_retry_exhausted.py" \
    --repo "$GITHUB_REPOSITORY" --run-id "$RUN_ID" --attempt "$RUN_ATTEMPT" --sha "$SHA"
  exit $?
fi
# A retry that repeats at once the GitHub call that just failed recovers nothing: run 45744507889 (2026-11-26)
# got "could not create workflow dispatch event: HTTP 500" once and the loop stopped. Each read and the dispatch
# back off (RETRY_BACKOFF_SECONDS, 30 60 120 240 by default, about 7.5 min in all) and are tried again; before a
# later dispatch the head is read again, so a push that moved it meanwhile still takes the slot.
read -r -a backoff <<< "${RETRY_BACKOFF_SECONDS:-30 60 120 240}"
attempt=0
while :; do
  if head=$(gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/nightly-next" --jq .object.sha) && [ -n "$head" ]; then
    if [ "$head" != "$SHA" ]; then
      echo "nightly-next moved to $head: its push run takes the group's pending place, so no retry"
      exit 0
    fi
    echo "retry $tries of 2 after run $RUN_ID attempt $RUN_ATTEMPT: build the nightly-next head again"
    if gh workflow run nightly.yml --repo "$GITHUB_REPOSITORY" --ref nightly-next -f nightly_next_loop_retry="$tries"; then
      exit 0
    fi
    what="the dispatch"
  else
    what="reading the nightly-next head"
  fi
  if [ "$attempt" -ge "${#backoff[@]}" ]; then
    echo "::error title=nightly-next retry::$what failed $((attempt + 1)) times over $(( ${backoff[*]/%/+} 0 )) s; the next push starts the loop again"
    exit 1
  fi
  echo "::warning title=nightly-next retry::$what failed; trying again in ${backoff[$attempt]} s"
  sleep "${backoff[$attempt]}"
  attempt=$((attempt + 1))
done
