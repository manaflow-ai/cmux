#!/usr/bin/env bash
# nightly.yml publish-nightly: "Upload nightly-next appcasts to R2". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
# Compare-and-swap: written only while the live feed's newest build is below this
# one (If-Match on the bytes read), so a slower older run never moves it back.
for appcast in $NIGHTLY_FEEDS; do
  python3 "$PUBLISH_TOOLING/ci/nightly-next-guard.py" appcast "nightly-out/$appcast"
  python3 "$PUBLISH_TOOLING/ci/publish-nightly-next-r2.py" write-feed --feed "nightly-out/$appcast" \
    --github-output "$GITHUB_OUTPUT"
done
# Release push, only when a feed was actually written (write-feed
# records feed_written=true): the presence worker re-reads the public
# nightly-next feed and tells connected NEXT apps at once. No secret
# (it only reads an allowlisted public appcast, and a build only ever
# moves up); a failure never fails the step, and the worker's minute
# cron catches up. RELEASE_POKE_URL comes from the step env, so a test
# running this body without it never calls production.
if [[ -n "${RELEASE_POKE_URL:-}" ]] && grep -qx 'feed_written=true' "$GITHUB_OUTPUT"; then
  curl -fsS -X POST --max-time 10 --retry 3 "$RELEASE_POKE_URL" \
    || echo "::warning::release poke failed; the minute cron will catch up"
fi
