#!/usr/bin/env bash
# Continue an accepted DMG submission so the published DMG carries the app
# with its own stapled ticket (published nightly and RC builds, which submit
# only and are finished here after the Ubuntu poller saw Accepted).
#
# Apple keys a ticket by code-directory hash. The first DMG submission's ticket
# covers the app inside, so the app is stapled from it. A DMG rebuilt around
# the stapled app is new data that no ticket covers, so it is signed and
# submitted once more (no wait), and that second submission is continued like
# any outer DMG: a bounded wait here, else the caller's outer recovery
# artifact and the poll-outer / staple-outer jobs. Its state has
# stapled_app=true; a state that already has it is only continued.
#
# Usage: resume-stapled-app-notarization.sh <state> <signed-app> <release-dmg> <immutable-dmg> <app-entitlements> <outer-state>
# The signing keychain must exist (the caller imports it); this script deletes
# it after the second DMG signature, before the continuation runs app checks.
set -euo pipefail
if [ "$#" -ne 6 ]; then
  echo "usage: resume-stapled-app-notarization.sh <state> <signed-app> <release-dmg> <immutable-dmg> <app-entitlements> <outer-state>" >&2
  exit 2
fi
STATE_FILE="$1"
APP_PATH="$2"
DMG_RELEASE="$3"
DMG_IMMUTABLE="$4"
APP_ENTITLEMENTS="$5"
OUTER_STATE="$6"
OUTER_LOG="${CMUX_OUTER_NOTARY_OUTPUT_FILE:-${OUTER_STATE}.log}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PACKAGE_TOOL="${CMUX_NOTARIZE_NIGHTLY_DMG_TOOL:-$ROOT_DIR/scripts/ci/notarize-nightly-dmg.sh}"
RESUME_TOOL="${CMUX_RESUME_NIGHTLY_NOTARIZATION_TOOL:-$ROOT_DIR/scripts/ci/resume-nightly-notarization.sh}"
SIGNING_KEYCHAIN_TOOL="${CMUX_SIGNING_KEYCHAIN_TOOL:-$ROOT_DIR/scripts/ci/signing-keychain.sh}"
[ -f "$STATE_FILE" ] || { echo "Notarization state not found: $STATE_FILE" >&2; exit 1; }
[ -d "$APP_PATH/Contents" ] || { echo "Recovered signed app not found: $APP_PATH" >&2; exit 1; }

if grep -Fxq 'stapled_app=true' "$STATE_FILE"; then
  # Already the DMG around the stapled app: continue it, build nothing.
  "$SIGNING_KEYCHAIN_TOOL" delete
  exec "$RESUME_TOOL" "$STATE_FILE" "$APP_PATH" "$DMG_RELEASE" "$DMG_IMMUTABLE"
fi
[ -f "$APP_ENTITLEMENTS" ] || { echo "App entitlements not found: $APP_ENTITLEMENTS" >&2; exit 1; }
: "${APPLE_SIGNING_IDENTITY:?APPLE_SIGNING_IDENTITY signs the DMG around the stapled app}"

# 1. The first submission: staple and check the app (and the first DMG). No
#    publication; the keychain still exists, so no app code runs here.
CMUX_RESUME_APP_ONLY=true \
CMUX_DEFER_LAUNCH_SMOKES=true \
  "$RESUME_TOOL" "$STATE_FILE" "$APP_PATH" "$DMG_RELEASE" "$DMG_IMMUTABLE"

# 2. Build, sign and submit (no wait) the DMG around the stapled app. It takes
#    the release path; the package tool deletes the keychain after its signature.
CMUX_STAPLE_APP_IN_DMG=false \
CMUX_COMPUTER_USE_HELPER_ALREADY_FINISHED=true \
CMUX_COMPUTER_USE_NOTARY_SUBMISSION_FILE= \
CMUX_NOTARY_SUBMIT_ONLY=true \
CMUX_SKIP_NOTARY_LOG=true \
CMUX_NOTARY_SUBMISSION_FILE="$OUTER_STATE" \
CMUX_NOTARY_OUTPUT_FILE="$OUTER_LOG" \
CMUX_APP_ENTITLEMENTS="$APP_ENTITLEMENTS" \
CHANNEL_RELEASE_TAG="${CHANNEL_RELEASE_TAG:-${CMUX_CHANNEL:-nightly}}" \
CHANNEL_DMG_PREFIX="${CHANNEL_DMG_PREFIX:-cmux-${CMUX_CHANNEL:-nightly}-macos}" \
NIGHTLY_VARIANT="${NIGHTLY_VARIANT:-universal}" \
  "$PACKAGE_TOOL" "$APP_PATH" "$DMG_RELEASE" "$DMG_IMMUTABLE"
"$SIGNING_KEYCHAIN_TOOL" delete
[ -f "$OUTER_STATE" ] || { echo "The stapled-app DMG state was not created: $OUTER_STATE" >&2; exit 1; }
printf 'stapled_app=true\n' >> "$OUTER_STATE"

# 3. A bounded wait on the second submission. A wait that runs out fails, and
#    the caller hands the outer state, log and DMG to its outer recovery path.
CMUX_NOTARY_WAIT_TIMEOUT="${CMUX_OUTER_NOTARY_WAIT_TIMEOUT:-60m}" \
CMUX_NOTARY_EVIDENCE_FILE="$OUTER_LOG" \
  "$RESUME_TOOL" "$OUTER_STATE" "$APP_PATH" "$DMG_RELEASE" "$DMG_IMMUTABLE"
