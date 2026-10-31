#!/usr/bin/env bash
# nightly.yml publish-release-notes: "Upload the signed release notes to R2". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
for file in notes/*; do
  name="$(basename "$file")"
  key="${NIGHTLY_NEXT_R2_PREFIX}notes/$name"
  python3 scripts/ci/nightly-next-guard.py r2-key "$NIGHTLY_NEXT_R2_BUCKET" "$key"
  case "$name" in index.json|index.json.sig|announcements.json|announcements.json.sig|flags.json|flags.json.sig) cache="no-cache, no-store, must-revalidate" ;; *) cache="public, max-age=3600" ;; esac
  case "$name" in *.json) type="application/json" ;; *) type="text/plain" ;; esac
  python3 scripts/ci/upload-r2-object.py --file "$file" --endpoint-url "$R2_ENDPOINT" \
    --bucket "$NIGHTLY_NEXT_R2_BUCKET" --key "$key" --content-type "$type" --cache-control "$cache"
done
