#!/usr/bin/env bash
# nightly.yml publish-nightly: "Read the live nightly-next feed before the write", the floor the
# read-back after it compares with (publish-next-feed-readback.sh). A 404 is recorded as "absent"
# (no feed yet, no floor); any other failure leaves no file, and the read-back then fails, since a
# regression could not be ruled out. Moved out of the workflow to keep nightly.yml under GitHub's
# workflow file size limit; the step's env: still sets every input.
set -uo pipefail
for appcast in $NIGHTLY_FEEDS; do
  out="$RUNNER_TEMP/before-$appcast"
  status=0
  code="$(curl -sSL --retry 5 --retry-all-errors -A "cmux-nightly-next-live-check/1" -H "Cache-Control: no-cache" \
    -o "$out" -w '%{http_code}' "${CHANNEL_FEED_BASE}/${appcast}?before=${GITHUB_RUN_ID}")" || status=$?
  if [ "$code" = 404 ]; then
    echo absent > "$out"
  elif [ "$status" != 0 ] || [ "$code" != 200 ]; then
    rm -f "$out"
    echo "::warning::could not read the live $appcast before the write (curl exit $status, HTTP ${code:-000})"
  fi
done
exit 0
