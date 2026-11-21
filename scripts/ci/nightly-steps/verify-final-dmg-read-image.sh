#!/usr/bin/env bash
# nightly.yml verify-final-dmg-nightly: "Read the final DMG's image for the parallel launch smoke". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# A pool-signed build's smoke ran in launch-smoke-nightly on the unsigned DMG: record the final DMG's image
# for publish-nightly to match. Any other build (or NIGHTLY_NEXT_PARALLEL_SMOKE=off) is smoked here.
image="$(python3 -I .publish-tooling/scripts/ci/dmg_image_digest.py "final-dmg/${CHANNEL_DMG_PREFIX}-arm64.dmg")"
echo "image=$image" >> "$GITHUB_OUTPUT"
