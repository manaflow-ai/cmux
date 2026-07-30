#!/usr/bin/env bash
# Independently notarize and staple the nested cmux Computer Use app.
#
# cmux copies this helper out of the signed host bundle before launch. An
# independent ticket keeps that copied app Gatekeeper-valid even when the Mac
# cannot contact Apple's notarization service. Stapling changes the nested
# bundle, so the outer cmux app is re-sealed afterward without re-signing the
# helper and discarding its ticket.

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <signed-host-app> <host-entitlements> <signing-identity>" >&2
  exit 2
fi

APP_PATH="$1"
APP_ENTITLEMENTS="$2"
SIGNING_IDENTITY="$3"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DITTO_TOOL="${CMUX_DITTO_TOOL:-/usr/bin/ditto}"
XCRUN_TOOL="${CMUX_XCRUN_TOOL:-xcrun}"
CODESIGN_TOOL="${CMUX_CODESIGN_TOOL:-/usr/bin/codesign}"
SPCTL_TOOL="${CMUX_SPCTL_TOOL:-spctl}"
SIGN_BUNDLE_TOOL="${CMUX_SIGN_BUNDLE_TOOL:-$ROOT_DIR/scripts/sign-cmux-bundle.sh}"
HELPER_PATH="$APP_PATH/Contents/Library/cmux Computer Use.app"

if [ ! -d "$APP_PATH/Contents" ]; then
  echo "Signed host app not found: $APP_PATH" >&2
  exit 1
fi
if [ ! -d "$HELPER_PATH/Contents" ]; then
  echo "Nested cmux Computer Use app not found: $HELPER_PATH" >&2
  exit 1
fi
if [ ! -f "$APP_ENTITLEMENTS" ]; then
  echo "Host entitlements not found: $APP_ENTITLEMENTS" >&2
  exit 1
fi
if [ -z "${APPLE_ID:-}" ] \
  || [ -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] \
  || [ -z "${APPLE_TEAM_ID:-}" ]; then
  echo "Missing notarization secrets (APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID)" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

HELPER_ZIP="$TMP_DIR/cmux-computer-use-notary.zip"
STANDALONE_DIR="$TMP_DIR/standalone"
STANDALONE_HELPER="$STANDALONE_DIR/cmux Computer Use.app"

"$CODESIGN_TOOL" --verify --strict --verbose=2 "$HELPER_PATH"
"$DITTO_TOOL" -c -k --sequesterRsrc --keepParent "$HELPER_PATH" "$HELPER_ZIP"

SUBMIT_JSON="$("$XCRUN_TOOL" notarytool submit "$HELPER_ZIP" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --wait \
  --output-format json)"
SUBMIT_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$SUBMIT_JSON")"
SUBMIT_STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$SUBMIT_JSON")"
if [ "$SUBMIT_STATUS" != "Accepted" ]; then
  echo "Computer Use helper notarization failed with status: $SUBMIT_STATUS" >&2
  "$XCRUN_TOOL" notarytool log "$SUBMIT_ID" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" || true
  exit 1
fi

"$XCRUN_TOOL" notarytool log "$SUBMIT_ID" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD"
"$XCRUN_TOOL" stapler staple "$HELPER_PATH"
"$XCRUN_TOOL" stapler validate "$HELPER_PATH"
"$CODESIGN_TOOL" --verify --strict --verbose=2 "$HELPER_PATH"

# Validate the same shape the runtime launches: a standalone copy outside the
# host app. This also proves that the stapled ticket survives the copy.
mkdir -p "$STANDALONE_DIR"
"$DITTO_TOOL" "$HELPER_PATH" "$STANDALONE_HELPER"
"$XCRUN_TOOL" stapler validate "$STANDALONE_HELPER"
"$CODESIGN_TOOL" --verify --strict --verbose=2 "$STANDALONE_HELPER"
"$SPCTL_TOOL" -a -vv --type execute "$STANDALONE_HELPER"

# Stapling the nested app changes the host's resource seal. Re-sign only the
# outer app: re-signing nested code here would discard the helper's ticket.
CMUX_SIGN_MODE=main-only \
  "$SIGN_BUNDLE_TOOL" "$APP_PATH" "$APP_ENTITLEMENTS" "$SIGNING_IDENTITY"
"$CODESIGN_TOOL" --verify --deep --strict --verbose=2 "$APP_PATH"
"$XCRUN_TOOL" stapler validate "$HELPER_PATH"

echo "Computer Use helper notarized and stapled: $HELPER_PATH"
