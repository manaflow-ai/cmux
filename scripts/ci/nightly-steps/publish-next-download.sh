#!/usr/bin/env bash
# nightly.yml publish-nightly: "Publish the nightly-next download to R2". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
# One feed per architecture (appcast-<variant>.xml); each names only its own DMG.
for feed in $NIGHTLY_FEEDS; do
  variant="${feed#appcast-}"
  dmg="${CHANNEL_DMG_PREFIX}-${variant%.xml}-${NIGHTLY_BUILD}.dmg"
  python3 "$PUBLISH_TOOLING/ci/publish-nightly-next-r2.py" upload --file "nightly-out/$dmg"
  python3 "$PUBLISH_TOOLING/ci/publish-nightly-next-r2.py" rewrite --feed "nightly-out/$feed" --name "$dmg"
done
