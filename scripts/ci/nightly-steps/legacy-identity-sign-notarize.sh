#!/usr/bin/env bash
# nightly.yml sign-nightly-identity-legacy: "Notarize the cmux NIGHTLY DMG". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# Same packaging, notarization, stapling, spctl and metadata checks as
# every NIGHTLY DMG; runtime checks stay out of this secret-bearing job. The Computer Use helper keeps
# its own stapled ticket (keep-stapled-computer-use-helper.sh).
# The DMG around the stapled app is signed after Apple's wait.
# This job holds signing and notarization secrets, so it runs no
# bundle code (#21024 guard rule 6). The follow-up job verifies this
# exact DMG's static artifact properties.
set -euo pipefail
mkdir -p legacy-out
: > "$RUNNER_TEMP/unused-helper-state"
continue_args=()
if [ "$LEGACY_ACTION" = continue ]; then
  # Asks Apple once about the recorded submission of this exact DMG.
  continue_args=("CMUX_NOTARY_CONTINUE_STATE=$RUNNER_TEMP/legacy.notarization.state")
fi
env ${continue_args[@]+"${continue_args[@]}"} \
  CMUX_CHANNEL=nightly \
  CMUX_NOTARY_WAIT_TIMEOUT=20m \
  CMUX_NOTARY_PENDING_ON_TIMEOUT=true \
  CMUX_NOTARIZE_COMPUTER_USE_HELPER_TOOL="$PWD/scripts/ci/keep-stapled-computer-use-helper.sh" \
  CMUX_COMPUTER_USE_NOTARY_SUBMISSION_FILE="$RUNNER_TEMP/unused-helper-state" \
  CMUX_NOTARY_SUBMISSION_FILE="$RUNNER_TEMP/legacy.notarization.state" \
  CMUX_NOTARY_OUTPUT_FILE="$RUNNER_TEMP/legacy.notarization.log" \
  ./scripts/ci/notarize-nightly-dmg.sh "legacy-app/cmux NIGHTLY.app" \
    "legacy-out/release.dmg" "legacy-out/${LEGACY_DMG_PREFIX}${NIGHTLY_BUILD}.dmg"
if grep -Fxq "submission_pending=true" "$GITHUB_OUTPUT"; then
  echo "### cmux NIGHTLY-identity build $NIGHTLY_BUILD is still in Apple's queue; a later run continues it (cx-x7hwx)" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi
codesign --verify --deep --strict --verbose=2 "legacy-app/cmux NIGHTLY.app"
spctl -a -vv --type execute "legacy-app/cmux NIGHTLY.app"
xcrun stapler validate "legacy-app/cmux NIGHTLY.app"
