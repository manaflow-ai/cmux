#!/usr/bin/env bash
# nightly.yml publish-nightly: "Upload nightly appcasts to R2". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
# Upload after the GitHub Release publish so no appcast references a
# DMG that doesn't exist yet. R2 PutObject is atomic, so each appcast is
# either the old version or the new one, never missing. Thin feeds go
# first: the app rewrites the legacy feed URL to a thin feed, so those
# must already be current when the legacy feed changes.
for appcast in $NIGHTLY_FEEDS; do
  python3 "$PUBLISH_TOOLING/ci/upload-r2-object.py" \
    --file "nightly-out/$appcast" \
    --endpoint-url "$R2_ENDPOINT" \
    --bucket cmux-binaries \
    --key "${CHANNEL_RELEASE_TAG}/$appcast" \
    --content-type "application/xml" \
    --cache-control "no-cache, no-store, must-revalidate"
  echo "R2 appcast upload complete: ${CHANNEL_FEED_BASE}/$appcast"
done
