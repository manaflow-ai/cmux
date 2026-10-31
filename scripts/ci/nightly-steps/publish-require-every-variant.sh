#!/usr/bin/env bash
# nightly.yml publish-nightly: "Require every variant". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
for variant in $(jq -r '.[]' <<< "$VARIANTS"); do
  [ -f "nightly-out/${CHANNEL_DMG_PREFIX}-${variant}-${NIGHTLY_BUILD}.dmg" ] || { echo "missing ${CHANNEL_DMG_PREFIX}-${variant}-${NIGHTLY_BUILD}.dmg: every variant ships or none does" >&2; exit 1; }
done
