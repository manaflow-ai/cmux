#!/usr/bin/env bash
# nightly.yml publish-nightly-identity-legacy: "Refuse a DMG that is not the tested one". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# Only the bytes the verify job statically verified are published.
./scripts/ci/nightly-next-legacy-tested-digest.sh \
  "legacy-out/${LEGACY_DMG_PREFIX}${NIGHTLY_BUILD}.dmg" "$TESTED_SHA256" "$SIGNED_SHA256"
