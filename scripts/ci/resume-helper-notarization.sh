#!/usr/bin/env bash
# Finish a recovered Computer Use submission, then create and resume the exact
# outer DMG submission. The helper state and signed app must come from one
# nightly recovery artifact.
set -euo pipefail

if [ "$#" -ne 7 ]; then
  echo "usage: resume-helper-notarization.sh <helper-state> <signed-app> <release-dmg> <immutable-dmg> <app-entitlements> <signing-identity> <outer-state>" >&2
  exit 2
fi

HELPER_STATE="$1"
APP_PATH="$2"
DMG_RELEASE="$3"
DMG_IMMUTABLE="$4"
APP_ENTITLEMENTS="$5"
SIGNING_IDENTITY="$6"
OUTER_STATE="$7"
OUTER_LOG="${CMUX_OUTER_NOTARY_OUTPUT_FILE:-${OUTER_STATE}.log}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER_TOOL="${CMUX_NOTARIZE_COMPUTER_USE_HELPER_TOOL:-$ROOT_DIR/scripts/ci/notarize-computer-use-helper.sh}"
PACKAGE_TOOL="${CMUX_NOTARIZE_NIGHTLY_DMG_TOOL:-$ROOT_DIR/scripts/ci/notarize-nightly-dmg.sh}"
RESUME_TOOL="${CMUX_RESUME_NIGHTLY_NOTARIZATION_TOOL:-$ROOT_DIR/scripts/ci/resume-nightly-notarization.sh}"

[ -f "$HELPER_STATE" ] || { echo "Computer Use helper state not found: $HELPER_STATE" >&2; exit 1; }
[ -d "$APP_PATH/Contents" ] || { echo "Recovered signed app not found: $APP_PATH" >&2; exit 1; }
[ -f "$APP_ENTITLEMENTS" ] || { echo "App entitlements not found: $APP_ENTITLEMENTS" >&2; exit 1; }

# The Ubuntu poll job admitted this exact helper submission only after Apple
# reported Accepted. The short wait here is a final race check before stapling;
# it never submits a second helper archive.
CMUX_HELPER_WAIT_TIMEOUT="${CMUX_HELPER_WAIT_TIMEOUT:-5m}" \
CMUX_HELPER_NOTARY_OUTPUT_FILE="${CMUX_HELPER_NOTARY_OUTPUT_FILE:-${HELPER_STATE}.log}" \
CMUX_APP_ENTITLEMENTS="$APP_ENTITLEMENTS" \
  "$HELPER_TOOL" --finish "$HELPER_STATE" "$APP_PATH" "$APP_ENTITLEMENTS" "$SIGNING_IDENTITY"

# Helper stapling changes the host resource seal, so package and submit the
# outer DMG only after helper finish. The outer state is then handed to the
# existing exact-DMG continuation, which verifies its SHA and Apple ticket.
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

[ -f "$OUTER_STATE" ] || { echo "Outer DMG notarization state was not created: $OUTER_STATE" >&2; exit 1; }
[ -s "$OUTER_LOG" ] || { echo "Outer DMG notarization evidence was not created: $OUTER_LOG" >&2; exit 1; }

CMUX_NOTARY_WAIT_TIMEOUT="${CMUX_OUTER_NOTARY_WAIT_TIMEOUT:-60m}" \
CMUX_NOTARY_EVIDENCE_FILE="$OUTER_LOG" \
  "$RESUME_TOOL" "$OUTER_STATE" "$APP_PATH" "$DMG_RELEASE" "$DMG_IMMUTABLE"
