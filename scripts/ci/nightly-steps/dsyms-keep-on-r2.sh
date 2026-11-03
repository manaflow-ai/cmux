#!/usr/bin/env bash
# nightly.yml keep-published-dsyms: "Keep the published build's dSYMs on R2". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
[[ "$BUILD" =~ ^[0-9]+$ && "$BUILD_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid build $BUILD at $BUILD_SHA" >&2; exit 1; }
archive="$RUNNER_TEMP/published-dsyms.tar.gz"
tar -C "$RUNNER_TEMP/published-dsyms" -czf "$archive" dSYMs
key="${NIGHTLY_NEXT_R2_PREFIX}dsyms/${BUILD_SHA}/${BUILD}/dSYMs.tar.gz"
python3 .publish-tooling/scripts/ci/nightly-next-guard.py r2-key "$NIGHTLY_NEXT_R2_BUCKET" "$key"
status=0
python3 .publish-tooling/scripts/ci/upload-r2-object.py --file "$archive" --endpoint-url "$R2_ENDPOINT" \
  --bucket "$NIGHTLY_NEXT_R2_BUCKET" --key "$key" --content-type application/gzip \
  --cache-control "private, max-age=0" --write-once --conflict-exit-code 75 || status=$?
case "$status" in
  0) echo "Published build $BUILD dSYMs: r2://$NIGHTLY_NEXT_R2_BUCKET/$key ($(du -h "$archive" | cut -f1))" >> "$GITHUB_STEP_SUMMARY" ;;
  75) echo "Published build $BUILD dSYMs were already kept at r2://$NIGHTLY_NEXT_R2_BUCKET/$key" >> "$GITHUB_STEP_SUMMARY" ;;
  *) exit "$status" ;;
esac
