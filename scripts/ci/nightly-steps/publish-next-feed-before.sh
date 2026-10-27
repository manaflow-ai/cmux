#!/usr/bin/env bash
# nightly.yml publish-nightly: "Read the live nightly-next feed before the write", for the
# read-back after it (publish-next-feed-readback.sh). Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -uo pipefail
for appcast in $NIGHTLY_FEEDS; do
  curl -fsSL --retry 3 -A "cmux-nightly-next-live-check/1" -H "Cache-Control: no-cache" \
    -o "$RUNNER_TEMP/before-$appcast" "${CHANNEL_FEED_BASE}/${appcast}?before=${GITHUB_RUN_ID}" \
    || echo "::warning::could not read the live $appcast before the write"
done
exit 0
