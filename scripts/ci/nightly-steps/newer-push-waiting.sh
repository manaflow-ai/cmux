#!/usr/bin/env bash
# nightly.yml nightly-next-one: "Hand the Mac to a newer nightly-next push after the feed".
# Once this build's feed is written, the job's tail (the bundle size report and the nearest deltas, 6-7 min of the
# signing Mac) only improves an item a newer build replaces within one build. When nightly-next already moved past
# this run's commit, a newer push is waiting for this Mac, so this sets NEWER_PUSH_WAITING=1 and those steps skip:
# the train goes on instead (docs/ci/nightly-workflow-notes.md#note-53). The dSYMs, artifacts and cleanup still run.
# Reads the ref with git ls-remote (no API budget), one try, bounded; an unknown read keeps the tail, as before.
# Env: TIP_SHA, REPOSITORY; NIGHTLY_NEXT_REMOTE (test override).
set -euo pipefail
here="$(dirname "${BASH_SOURCE[0]}")"
head=""
if refs="$(bash "$here/../timeout.sh" 30 git ls-remote "${NIGHTLY_NEXT_REMOTE:-https://github.com/$REPOSITORY}" refs/heads/nightly-next)"; then
  head="$(printf '%s\n' "$refs" | cut -f1 | head -1)"
fi
if [[ "$head" =~ ^[0-9a-f]{40}$ && "$head" != "$TIP_SHA" ]]; then
  echo "NEWER_PUSH_WAITING=1" >> "$GITHUB_ENV"
  echo "::notice title=Train goes on::nightly-next moved from $TIP_SHA to $head; this build's feed is live, so its deltas and size report skip and the Mac goes to the newer push"
else
  echo "nightly-next is still ${head:-unknown} (this build: $TIP_SHA); the tail runs"
fi
