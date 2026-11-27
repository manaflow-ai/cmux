#!/usr/bin/env bash
# nightly.yml build-nightly-deltas: "Build the deltas without the key". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
feed="appcast.xml"
if [ "$NIGHTLY_VARIANT" != "universal" ]; then
  feed="appcast-${NIGHTLY_VARIANT}.xml"
fi
./.publish-tooling/scripts/ci/generate-nightly-deltas.sh \
  "$RUNNER_TEMP/nightly-delta/input/${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}-${NIGHTLY_BUILD}.dmg" \
  "$RUNNER_TEMP/nightly-delta/input/$feed" nightly-delta/prebuilt
rm -f nightly-delta/prebuilt/*.xml
ls -l nightly-delta/prebuilt
