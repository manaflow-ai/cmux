#!/usr/bin/env bash
# nightly.yml publish-nightly: "Publish the nightly-next download to R2". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
dmg="${CHANNEL_DMG_PREFIX}-arm64-${NIGHTLY_BUILD}.dmg"
r2="$PUBLISH_TOOLING/ci/publish-nightly-next-r2.py"
# The DMG's EdDSA signature beside it, so the app can check a build the feed no longer lists
# before it installs it (What's New and Settings' Install this version, `cmux nightly install`).
feeds=()
for feed in $NIGHTLY_FEEDS; do feeds+=(--feed "nightly-out/$feed"); done
python3 "$r2" signature "${feeds[@]}" --name "$dmg" \
  --out "nightly-out/$dmg.signature.json"
python3 "$r2" upload --file "nightly-out/$dmg" --file "nightly-out/$dmg.signature.json"
for feed in $NIGHTLY_FEEDS; do
  python3 "$r2" rewrite --feed "nightly-out/$feed" --name "$dmg"
done
# This build's deltas (appcast-with-nearest-deltas.sh, hq#13299), beside the DMG. Optional: a failed
# upload leaves that delta's GitHub URL, which prune drops, and the feed offers the rest; no delta at all
# still publishes the build, the full DMG for every Mac.
deltas=()
for delta in nightly-out/"${CHANNEL_DMG_PREFIX}"-arm64-"${NIGHTLY_BUILD}"-*.delta; do
  if [ -f "$delta" ]; then deltas+=(--file "$delta"); fi
done
if [ "${#deltas[@]}" -gt 0 ]; then
  python3 "$r2" upload "${deltas[@]}" || echo "::warning::Some deltas did not reach R2; the feed offers the ones that did"
fi
if [ -f "$PUBLISH_TOOLING/ci/nightly_next_delta_check.py" ]; then
  for feed in $NIGHTLY_FEEDS; do
    python3 "$r2" rewrite --feed "nightly-out/$feed" --if-public
    python3 "$PUBLISH_TOOLING/ci/nightly_next_delta_check.py" prune "nightly-out/$feed" --base "${NIGHTLY_NEXT_FEED_BASE%/}/"
  done
fi
