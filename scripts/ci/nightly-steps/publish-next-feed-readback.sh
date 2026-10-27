#!/usr/bin/env bash
# nightly.yml publish-nightly: "Read the live nightly-next feed back". Leo, 2026-10-27: "but why
# shoudl there be a delay if we can just listen". Fails right after the write when the live feed
# offers the default Nightly app nothing new (scripts/ci/nightly_next_live_feed_check.py).
# Moved out of the workflow to keep nightly.yml under GitHub's workflow file size limit.
set -euo pipefail
status=0
for appcast in $NIGHTLY_FEEDS; do
  before=()
  [ -s "$RUNNER_TEMP/before-$appcast" ] && before=(--before "$RUNNER_TEMP/before-$appcast")
  python3 "$PUBLISH_TOOLING/ci/nightly_next_live_feed_check.py" --feed-url "${CHANNEL_FEED_BASE}/${appcast}" \
    --build "$NIGHTLY_BUILD" --dev-ring "$DEV_RING" ${before[@]+"${before[@]}"} || status=1
done
exit "$status"
