#!/usr/bin/env bash
# nightly.yml verify-signed-nightly: "Verify signed diff sidecar protocol contract". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# sign-cmux-bundle.sh ran the static sidecar checks while the keychain
# existed. Recheck the signed sidecar's deterministic transport contract
# after the keychain is gone; this does not launch the app.
set -euo pipefail
./scripts/verify-diff-sidecar-artifact.sh \
  "$CHANNEL_APP_PATH/Contents/Resources/bin/cmux-diff-sidecar" \
  --archs "$(lipo -archs "$CHANNEL_APP_PATH/Contents/MacOS/cmux")" \
  --require-signed
