#!/usr/bin/env bash
# nightly.yml publish-nightly: "Publish the nightly-next download to R2". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
dmg="${CHANNEL_DMG_PREFIX}-arm64-${NIGHTLY_BUILD}.dmg"
python3 "$PUBLISH_TOOLING/ci/publish-nightly-next-r2.py" upload --file "nightly-out/$dmg"
for feed in $NIGHTLY_FEEDS; do
  python3 "$PUBLISH_TOOLING/ci/publish-nightly-next-r2.py" rewrite --feed "nightly-out/$feed" --name "$dmg"
done
