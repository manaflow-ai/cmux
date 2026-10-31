#!/usr/bin/env bash
# nightly.yml publish-nightly: "Tag the new build's items from the live Dev ring switch". The build
# job tagged its items from its own snapshot of the switch; the feed goes out tagged from the live
# one (a Dev item stays Dev only while the ring is on and no pass). Moved out of the workflow to
# keep nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
for appcast in $NIGHTLY_FEEDS; do
  python3 "$PUBLISH_TOOLING/ci/nightly_next_ring.py" retag --feed "nightly-out/$appcast" \
    --out "nightly-out/$appcast" --mode "$DEV_RING" --verdicts-base "$NIGHTLY_NEXT_FEED_BASE"
done
