#!/usr/bin/env bash
# nightly.yml republish-nightly-deltas: "Upload revised appcasts to R2". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
for feed in nightly-deltas/appcast*.xml; do
  [ -f "$feed" ] || continue
  name="$(basename "$feed")"
  python3 scripts/ci/upload-r2-object.py \
    --file "$feed" \
    --endpoint-url "$R2_ENDPOINT" \
    --bucket cmux-binaries \
    --key "${CHANNEL_RELEASE_TAG}/$name" \
    --content-type "application/xml" \
    --cache-control "no-cache, no-store, must-revalidate"
done
