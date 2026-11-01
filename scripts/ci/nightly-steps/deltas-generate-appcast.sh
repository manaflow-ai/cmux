#!/usr/bin/env bash
# nightly.yml generate-nightly-deltas: "Generate deltas and revised appcast". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# The nightly-next track gets only its own key; the others never see it.
set -euo pipefail
feed="appcast.xml"
if [ "$NIGHTLY_VARIANT" != "universal" ]; then
  feed="appcast-${NIGHTLY_VARIANT}.xml"
fi
./scripts/ci/generate-nightly-deltas.sh \
  "nightly-delta/input/${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}-${NIGHTLY_BUILD}.dmg" \
  "nightly-delta/input/$feed" nightly-delta/output
ls -l nightly-delta/output
