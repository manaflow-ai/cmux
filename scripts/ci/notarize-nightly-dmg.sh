#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <signed-app> <release-dmg> <immutable-dmg>" >&2
  exit 2
fi

APP_PATH="$1"
DMG_RELEASE="$2"
DMG_IMMUTABLE="$3"
CREATE_DMG_TOOL="${CMUX_CREATE_DMG_TOOL:-create-dmg}"
CODESIGN_TOOL="${CMUX_CODESIGN_TOOL:-/usr/bin/codesign}"
XCRUN_TOOL="${CMUX_XCRUN_TOOL:-xcrun}"
HDIUTIL_TOOL="${CMUX_HDIUTIL_TOOL:-hdiutil}"
SPCTL_TOOL="${CMUX_SPCTL_TOOL:-spctl}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SMOKE_TOOL="${CMUX_SMOKE_TOOL:-$ROOT_DIR/scripts/smoke-launch-macos-app.sh}"
VERIFY_METADATA_TOOL="${CMUX_VERIFY_METADATA_TOOL:-$ROOT_DIR/scripts/verify-app-bundle-channel-metadata.sh}"
VERIFY_LICENSES_TOOL="${CMUX_VERIFY_LICENSES_TOOL:-$ROOT_DIR/scripts/verify-app-bundle-licenses.sh}"
NOTARIZE_COMPUTER_USE_HELPER_TOOL="${CMUX_NOTARIZE_COMPUTER_USE_HELPER_TOOL:-$ROOT_DIR/scripts/ci/notarize-computer-use-helper.sh}"
COMPUTER_USE_NOTARY_SUBMISSION_FILE="${CMUX_COMPUTER_USE_NOTARY_SUBMISSION_FILE:-}"
# Release channel of the app being packaged: `nightly` (default) or `rc`. It
# selects the entitlements file and the bundle-metadata check; the packaging,
# notarization, and stapling steps are identical for both.
CHANNEL="${CMUX_CHANNEL:-nightly}"
case "$CHANNEL" in
  nightly|rc) ;;
  *)
    echo "Unsupported CMUX_CHANNEL: $CHANNEL (expected nightly or rc)" >&2
    exit 2
    ;;
esac
APP_ENTITLEMENTS="${CMUX_APP_ENTITLEMENTS:-$ROOT_DIR/cmux.${CHANNEL}.entitlements}"
# shellcheck source=lib/notary-auth.sh
source "$ROOT_DIR/scripts/ci/lib/notary-auth.sh"

if [ ! -d "$APP_PATH/Contents" ]; then
  echo "Signed app not found: $APP_PATH" >&2
  exit 1
fi
if [ -z "${ASC_API_KEY_ID:-}" ] || [ -z "${ASC_API_ISSUER_ID:-}" ] || [ -z "${ASC_API_KEY_P8_BASE64:-}" ]; then
  echo "Missing notarization secrets (ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64)" >&2
  exit 1
fi
if [ -z "${APPLE_SIGNING_IDENTITY:-}" ]; then
  echo "Missing APPLE_SIGNING_IDENTITY" >&2
  exit 1
fi

DMG_TMP_DIR="$(mktemp -d)"
MOUNT_DIR=""
detach_mounted_dmg() {
  [ -n "$MOUNT_DIR" ] || return 0
  "$HDIUTIL_TOOL" detach "$MOUNT_DIR" || "$HDIUTIL_TOOL" detach -force "$MOUNT_DIR"
  rmdir "$MOUNT_DIR"
  MOUNT_DIR=""
}
cleanup() {
  if [ -n "$MOUNT_DIR" ]; then
    detach_mounted_dmg || true
  fi
  rm -rf "$DMG_TMP_DIR"
}
trap cleanup EXIT
NOTARY_DIR="$DMG_TMP_DIR/notary"
mkdir -m 700 "$NOTARY_DIR"
notary_auth_init "$NOTARY_DIR"

# cmux-next ships no nested Computer Use helper; only a bundle that carries
# one needs its separate notarization and host reseal.
if [ ! -d "$APP_PATH/Contents/Library/cmux Computer Use.app" ]; then
  echo "No nested cmux Computer Use app; skipping its notarization"
elif [ -n "$COMPUTER_USE_NOTARY_SUBMISSION_FILE" ]; then
  "$NOTARIZE_COMPUTER_USE_HELPER_TOOL" \
    --finish "$COMPUTER_USE_NOTARY_SUBMISSION_FILE" \
    "$APP_PATH" \
    "$APP_ENTITLEMENTS" \
    "$APPLE_SIGNING_IDENTITY"
else
  "$NOTARIZE_COMPUTER_USE_HELPER_TOOL" \
    "$APP_PATH" \
    "$APP_ENTITLEMENTS" \
    "$APPLE_SIGNING_IDENTITY"
fi

"$CREATE_DMG_TOOL" --no-code-sign "$APP_PATH" "$DMG_TMP_DIR"
CREATED_DMG="$(find "$DMG_TMP_DIR" -maxdepth 1 -name '*.dmg' -print -quit)"
if [ -z "$CREATED_DMG" ]; then
  echo "Failed to locate created DMG for $APP_PATH" >&2
  exit 1
fi
# create-dmg emits an LZFSE (ULFO) image. Re-encode to LZMA (ULMO): same bundle,
# about a quarter smaller download, and every supported macOS (14+) mounts it.
"$HDIUTIL_TOOL" convert "$CREATED_DMG" -quiet -format ULMO -ov -o "$DMG_RELEASE"
rm -f "$CREATED_DMG"
DMG_FORMAT="$("$HDIUTIL_TOOL" imageinfo "$DMG_RELEASE" | awk -F': *' '/^Format:/ {print $2; exit}')"
if [ "$DMG_FORMAT" != "ULMO" ]; then
  echo "Expected ULMO (LZMA) DMG after conversion, got: ${DMG_FORMAT:-unknown}" >&2
  exit 1
fi

"$CODESIGN_TOOL" --force --timestamp --keychain build.keychain \
  --sign "$APPLE_SIGNING_IDENTITY" \
  "$DMG_RELEASE"
"$CODESIGN_TOOL" --verify --verbose=2 "$DMG_RELEASE"

# A notary submission usually finishes in about 5 minutes. Bound the wait so a
# stuck one fails the job quickly with its id (run 37620073632 waited 78
# minutes until the job was cancelled).
NOTARY_WAIT_TIMEOUT="${CMUX_NOTARY_WAIT_TIMEOUT:-25m}"
if ! DMG_SUBMIT_JSON="$("$XCRUN_TOOL" notarytool submit "$DMG_RELEASE" "${NOTARY_AUTH_ARGS[@]}" \
    --wait --timeout "$NOTARY_WAIT_TIMEOUT" --output-format json)"; then
  echo "DMG notarization did not finish within $NOTARY_WAIT_TIMEOUT for $DMG_RELEASE: ${DMG_SUBMIT_JSON:-no notarytool output}" >&2
  exit 1
fi
DMG_SUBMIT_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$DMG_SUBMIT_JSON")"
DMG_STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$DMG_SUBMIT_JSON")"
if [ "$DMG_STATUS" != "Accepted" ]; then
  echo "DMG notarization failed for $DMG_RELEASE with status: $DMG_STATUS" >&2
  "$XCRUN_TOOL" notarytool log "$DMG_SUBMIT_ID" "${NOTARY_AUTH_ARGS[@]}" || true
  exit 1
fi

# A DMG submission scans nested code and issues a ticket for the exact signed
# app. Require that independently usable ticket before accepting the artifact.
"$XCRUN_TOOL" stapler staple "$APP_PATH"
"$XCRUN_TOOL" stapler validate "$APP_PATH"
"$SPCTL_TOOL" -a -vv --type execute "$APP_PATH"
CMUX_SMOKE_ALLOW_UNSUPPORTED_GUI=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$APP_PATH"
CMUX_SMOKE_DIRECT_EXEC=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$APP_PATH"
"$VERIFY_METADATA_TOOL" "$APP_PATH" "$CHANNEL"
"$VERIFY_LICENSES_TOOL" "$APP_PATH"

"$XCRUN_TOOL" stapler staple "$DMG_RELEASE"
"$XCRUN_TOOL" stapler validate "$DMG_RELEASE"

# Validate the delivered app inside the final stapled DMG, not only the source
# bundle that create-dmg consumed.
if [ -n "${CMUX_NIGHTLY_MOUNT_DIR:-}" ]; then
  MOUNT_DIR="$CMUX_NIGHTLY_MOUNT_DIR"
  mkdir -p "$MOUNT_DIR"
else
  MOUNT_DIR="$(mktemp -d)"
fi
"$HDIUTIL_TOOL" attach "$DMG_RELEASE" -nobrowse -readonly -mountpoint "$MOUNT_DIR"
MOUNTED_APP="$(find "$MOUNT_DIR" -maxdepth 1 -name '*.app' -type d -print -quit)"
if [ -z "$MOUNTED_APP" ]; then
  echo "No app found in mounted $CHANNEL DMG" >&2
  exit 1
fi
"$SPCTL_TOOL" -a -vv --type execute "$MOUNTED_APP"
CMUX_SMOKE_ALLOW_UNSUPPORTED_GUI=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$MOUNTED_APP"
CMUX_SMOKE_DIRECT_EXEC=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$MOUNTED_APP"
"$VERIFY_METADATA_TOOL" "$MOUNTED_APP" "$CHANNEL"
"$VERIFY_LICENSES_TOOL" "$MOUNTED_APP"
detach_mounted_dmg

cp "$DMG_RELEASE" "$DMG_IMMUTABLE"
