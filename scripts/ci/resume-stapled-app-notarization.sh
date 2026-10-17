#!/usr/bin/env bash
# Continue an accepted DMG submission so the published DMG carries the app
# with its own stapled ticket (published nightly and RC builds, which submit
# only and are finished after the Ubuntu poller saw Accepted).
#
# Apple keys a ticket by code-directory hash. The first DMG submission's ticket
# covers the app inside, so the app is stapled from it. A DMG rebuilt around
# the stapled app is new data that no ticket covers, so it is signed and
# submitted once more (no wait), and that second submission is continued like
# any outer DMG: a bounded wait here, else the caller hands <outer-state>, its
# log and the DMG it names to its outer recovery path. That state has
# stapled_app=true; a state that already has it is only continued.
#
# Usage: resume-stapled-app-notarization.sh <state> <signed-app> <release-dmg> <immutable-dmg> <app-entitlements> <outer-state>
#
# - The first wait uses CMUX_NOTARY_WAIT_TIMEOUT and CMUX_NOTARY_EVIDENCE_FILE;
#   the second wait uses CMUX_STAPLED_APP_NOTARY_WAIT_TIMEOUT (default 40m).
# - The DMG around the stapled app is built at
#   <release-dmg dir>/stapled-app/<release-dmg name> (CMUX_STAPLED_APP_DMG)
#   and replaces <release-dmg> only after Apple accepted it and it is stapled.
#   Until then <release-dmg> stays the accepted, stapled first DMG.
# - APPLE_CERTIFICATE_BASE64 and APPLE_CERTIFICATE_PASSWORD go only to
#   signing-keychain.sh create, which runs just before the second signature;
#   the package tool deletes the keychain after that signature.
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
OUTER_LOG="${OUTER_STATE}.log"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PACKAGE_TOOL="${CMUX_NOTARIZE_NIGHTLY_DMG_TOOL:-$ROOT_DIR/scripts/ci/notarize-nightly-dmg.sh}"
RESUME_TOOL="${CMUX_RESUME_NIGHTLY_NOTARIZATION_TOOL:-$ROOT_DIR/scripts/ci/resume-nightly-notarization.sh}"
SIGNING_KEYCHAIN_TOOL="${CMUX_SIGNING_KEYCHAIN_TOOL:-$ROOT_DIR/scripts/ci/signing-keychain.sh}"
STAPLED_DMG="${CMUX_STAPLED_APP_DMG:-$(dirname "$DMG_RELEASE")/stapled-app/$(basename "$DMG_RELEASE")}"
STAPLED_WAIT_TIMEOUT="${CMUX_STAPLED_APP_NOTARY_WAIT_TIMEOUT:-40m}"
# Kept out of every child process except the keychain create below.
CERT_BASE64="${APPLE_CERTIFICATE_BASE64:-}"
CERT_PASSWORD="${APPLE_CERTIFICATE_PASSWORD:-}"
unset APPLE_CERTIFICATE_BASE64 APPLE_CERTIFICATE_PASSWORD
[ -f "$STATE_FILE" ] || { echo "Notarization state not found: $STATE_FILE" >&2; exit 1; }
[ -d "$APP_PATH/Contents" ] || { echo "Recovered signed app not found: $APP_PATH" >&2; exit 1; }

if grep -Fxq 'stapled_app=true' "$STATE_FILE"; then
  # Already the DMG around the stapled app: continue it, build nothing.
  "$SIGNING_KEYCHAIN_TOOL" delete
  exec "$RESUME_TOOL" "$STATE_FILE" "$APP_PATH" "$DMG_RELEASE" "$DMG_IMMUTABLE"
fi
[ -f "$APP_ENTITLEMENTS" ] || { echo "App entitlements not found: $APP_ENTITLEMENTS" >&2; exit 1; }
: "${APPLE_SIGNING_IDENTITY:?APPLE_SIGNING_IDENTITY signs the DMG around the stapled app}"
if [ -z "$CERT_BASE64" ] || [ -z "$CERT_PASSWORD" ]; then
  echo "Missing APPLE_CERTIFICATE_BASE64 or APPLE_CERTIFICATE_PASSWORD: the DMG around the stapled app is signed" >&2
  exit 1
fi
if [ "$STAPLED_DMG" = "$DMG_RELEASE" ] || [ "$(basename "$STAPLED_DMG")" != "$(basename "$DMG_RELEASE")" ]; then
  echo "The DMG around the stapled app must have the release name at another path: $STAPLED_DMG" >&2
  exit 1
fi
cleanup() {
  "$SIGNING_KEYCHAIN_TOOL" delete >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 1. The first submission: staple and check the app and the first DMG. No
#    publication and no keychain, so no signing identity exists here.
"$SIGNING_KEYCHAIN_TOOL" delete
CMUX_RESUME_APP_ONLY=true \
CMUX_DEFER_LAUNCH_SMOKES=true \
  "$RESUME_TOOL" "$STATE_FILE" "$APP_PATH" "$DMG_RELEASE" "$DMG_IMMUTABLE"

# 2. Build, sign and submit (no wait) the DMG around the stapled app at its own
#    path. The keychain exists from here to the package tool's signature.
mkdir -p "$(dirname "$STAPLED_DMG")"
rm -f "$STAPLED_DMG" "$OUTER_STATE" "$OUTER_LOG"
APPLE_CERTIFICATE_BASE64="$CERT_BASE64" APPLE_CERTIFICATE_PASSWORD="$CERT_PASSWORD" \
  "$SIGNING_KEYCHAIN_TOOL" create
CERT_BASE64=""
CERT_PASSWORD=""
CMUX_STAPLE_APP_IN_DMG=false \
CMUX_COMPUTER_USE_HELPER_ALREADY_FINISHED=true \
CMUX_COMPUTER_USE_NOTARY_SUBMISSION_FILE="" \
CMUX_NOTARY_SUBMIT_ONLY=true \
CMUX_SKIP_NOTARY_LOG=true \
CMUX_NOTARY_STATE_STAPLED_APP=true \
CMUX_NOTARY_SUBMISSION_FILE="$OUTER_STATE" \
CMUX_NOTARY_OUTPUT_FILE="$OUTER_LOG" \
CMUX_APP_ENTITLEMENTS="$APP_ENTITLEMENTS" \
CHANNEL_RELEASE_TAG="${CHANNEL_RELEASE_TAG:-${CMUX_CHANNEL:-nightly}}" \
CHANNEL_DMG_PREFIX="${CHANNEL_DMG_PREFIX:-cmux-${CMUX_CHANNEL:-nightly}-macos}" \
NIGHTLY_VARIANT="${NIGHTLY_VARIANT:-universal}" \
  "$PACKAGE_TOOL" "$APP_PATH" "$STAPLED_DMG" "$DMG_IMMUTABLE"
"$SIGNING_KEYCHAIN_TOOL" delete
if ! grep -Fxq 'stapled_app=true' "$OUTER_STATE" 2>/dev/null || [ ! -s "$OUTER_LOG" ]; then
  echo "The stapled-app DMG state or its evidence was not created: $OUTER_STATE" >&2
  exit 1
fi

# 3. A bounded wait on the second submission. A wait that runs out fails, and
#    the caller hands <outer-state>, its log and the DMG it names to its outer
#    recovery path. The helper of this same app was checked in step 1.
CMUX_SKIP_HELPER_RECHECK=true \
CMUX_NOTARY_WAIT_TIMEOUT="$STAPLED_WAIT_TIMEOUT" \
CMUX_NOTARY_EVIDENCE_FILE="$OUTER_LOG" \
  "$RESUME_TOOL" "$OUTER_STATE" "$APP_PATH" "$STAPLED_DMG" "$DMG_IMMUTABLE"
# Accepted, stapled and checked: only now does it replace the first DMG.
/bin/mv -f "$STAPLED_DMG" "$DMG_RELEASE"
echo "The DMG around the stapled app is accepted and replaces the first DMG: $DMG_RELEASE"
