#!/usr/bin/env bash
# nightly.yml publish-nightly: "Publish the nightly-next download to R2". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
dmg="${CHANNEL_DMG_PREFIX}-arm64-${NIGHTLY_BUILD}.dmg"
# The DMG's EdDSA signature beside it, so the app can check a build the feed no longer lists
# before it installs it (What's New and Settings' Install this version, `cmux nightly install`).
feeds=()
for feed in $NIGHTLY_FEEDS; do feeds+=(--feed "nightly-out/$feed"); done
python3 "$PUBLISH_TOOLING/ci/publish-nightly-next-r2.py" signature "${feeds[@]}" --name "$dmg" \
  --out "nightly-out/$dmg.signature.json"
python3 "$PUBLISH_TOOLING/ci/publish-nightly-next-r2.py" upload --file "nightly-out/$dmg" --file "nightly-out/$dmg.signature.json"
for feed in $NIGHTLY_FEEDS; do
  python3 "$PUBLISH_TOOLING/ci/publish-nightly-next-r2.py" rewrite --feed "nightly-out/$feed" --name "$dmg"
done
