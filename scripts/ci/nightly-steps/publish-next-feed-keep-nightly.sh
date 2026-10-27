#!/usr/bin/env bash
# nightly.yml publish-nightly: "Keep the live feed's newest Nightly item beside the new build".
# The new build's feed alone drops every earlier item, so a Nightly-ring app (cmux-next only) is
# offered nothing while the new build waits on Dev for its verdict, and a later pass on that build
# can never promote it here. Combined as the old feed is (nightly_next_ring.py legacy): the new
# build, the newest cmux-next item and at most five Dev items above it, each tagged from its
# verdict. With the ring off every item is cmux-next and only the new build stays.
# Moved out of the workflow to keep nightly.yml under GitHub's workflow file size limit.
set -euo pipefail
for feed in $NIGHTLY_FEEDS; do
  current=()
  if curl -fsSL --retry 3 -A "cmux-nightly-next-feed/1" -H "Cache-Control: no-cache" \
      -o "$RUNNER_TEMP/live-$feed" "${CHANNEL_FEED_BASE}/${feed}?keep=${GITHUB_RUN_ID}"; then
    current=(--current "$RUNNER_TEMP/live-$feed")
  else
    echo "::warning::could not read the live $feed; publishing the new build's item alone"
  fi
  python3 "$PUBLISH_TOOLING/ci/nightly_next_ring.py" legacy --new "nightly-out/$feed" "${current[@]}" \
    --out "nightly-out/$feed" --mode "$DEV_RING" --verdicts-base "$NIGHTLY_NEXT_FEED_BASE"
done
