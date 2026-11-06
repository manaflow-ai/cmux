#!/usr/bin/env bash
# nightly.yml recover-nightly-next-notarization: "Generate the recovered Sparkle appcast". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# A recovered build is new to the feed: Dev first, as in build-sign-notarize-nightly.
set -euo pipefail
SPARKLE_PRIVATE_KEY="$(./scripts/ci/nightly-sparkle-key.sh)"
export SPARKLE_PRIVATE_KEY
SPARKLE_MINIMUM_SYSTEM_VERSION="$(python3 scripts/ci/appcast_minimum_system_version.py floor "$RECOVERED_APP")"
export SPARKLE_MINIMUM_SYSTEM_VERSION
SPARKLE_DELTA_NAME_PREFIX="${CHANNEL_DMG_PREFIX}-arm64-" \
  ./scripts/sparkle_generate_appcast.sh "$RECOVERED_IMMUTABLE" "$CHANNEL_RELEASE_TAG" recovered/appcast-arm64.xml
if grep -q 'sparkle:deltas' recovered/appcast-arm64.xml; then
  echo "ERROR: first publication appcasts must contain full archives only" >&2
  exit 1
fi
python3 scripts/ci/nightly-next-guard.py appcast recovered/appcast-arm64.xml
ls -l recovered
