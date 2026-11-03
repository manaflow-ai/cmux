#!/usr/bin/env bash
# nightly.yml publish-nightly: "Upload nightly-next appcasts to R2". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
# Compare-and-swap: written only while the live feed's newest build is below this
# one (If-Match on the bytes read), and only when this source descends from the
# live source. Build numbers are run ids, so they cannot establish source order.
: "${SOURCE_SHA:?the publication source SHA is required}"
result="$(mktemp)"
trap 'rm -f "$result"' EXIT
written=false current=true refused=false
for appcast in $NIGHTLY_FEEDS; do
  : > "$result"
  python3 "$PUBLISH_TOOLING/ci/nightly-next-guard.py" appcast "nightly-out/$appcast"
  python3 "$PUBLISH_TOOLING/ci/publish-nightly-next-r2.py" write-feed --feed "nightly-out/$appcast" \
    --source-sha "$SOURCE_SHA" --github-output "$result"
  if grep -qx 'feed_written=true' "$result"; then written=true; fi
  if ! grep -qx 'feed_current=true' "$result"; then current=false; fi
  if grep -qx 'publication_refused=true' "$result"; then refused=true; fi
done
# One refused feed must never be hidden by a later accepted feed's outputs.
printf 'feed_written=%s\nfeed_current=%s\npublication_refused=%s\n' \
  "$written" "$current" "$refused" >> "$GITHUB_OUTPUT"
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
