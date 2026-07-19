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

if [ ! -d "$APP_PATH/Contents" ]; then
  echo "Signed app not found: $APP_PATH" >&2
  exit 1
fi
if [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ]; then
  echo "Missing notarization secrets (APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID)" >&2
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

"$CREATE_DMG_TOOL" --no-code-sign "$APP_PATH" "$DMG_TMP_DIR"
CREATED_DMG="$(find "$DMG_TMP_DIR" -maxdepth 1 -name '*.dmg' -print -quit)"
if [ -z "$CREATED_DMG" ]; then
  echo "Failed to locate created DMG for $APP_PATH" >&2
  exit 1
fi
mv "$CREATED_DMG" "$DMG_RELEASE"

"$CODESIGN_TOOL" --force --timestamp --keychain build.keychain \
  --sign "$APPLE_SIGNING_IDENTITY" \
  "$DMG_RELEASE"
"$CODESIGN_TOOL" --verify --verbose=2 "$DMG_RELEASE"

DMG_SUBMIT_JSON="$("$XCRUN_TOOL" notarytool submit "$DMG_RELEASE" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait --output-format json)"
DMG_SUBMIT_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$DMG_SUBMIT_JSON")"
DMG_STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$DMG_SUBMIT_JSON")"
if [ "$DMG_STATUS" != "Accepted" ]; then
  echo "DMG notarization failed for $DMG_RELEASE with status: $DMG_STATUS" >&2
  "$XCRUN_TOOL" notarytool log "$DMG_SUBMIT_ID" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" || true
  exit 1
fi

# A DMG submission scans nested code and issues a ticket for the exact signed
# app. Require that independently usable ticket before accepting the artifact.
"$XCRUN_TOOL" stapler staple "$APP_PATH"
"$XCRUN_TOOL" stapler validate "$APP_PATH"
"$SPCTL_TOOL" -a -vv --type execute "$APP_PATH"
CMUX_SMOKE_ALLOW_UNSUPPORTED_GUI=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$APP_PATH"
CMUX_SMOKE_DIRECT_EXEC=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$APP_PATH"
"$VERIFY_METADATA_TOOL" "$APP_PATH" nightly
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
  echo "No app found in mounted nightly DMG" >&2
  exit 1
fi
"$SPCTL_TOOL" -a -vv --type execute "$MOUNTED_APP"
CMUX_SMOKE_ALLOW_UNSUPPORTED_GUI=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$MOUNTED_APP"
CMUX_SMOKE_DIRECT_EXEC=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$MOUNTED_APP"
"$VERIFY_METADATA_TOOL" "$MOUNTED_APP" nightly
"$VERIFY_LICENSES_TOOL" "$MOUNTED_APP"
detach_mounted_dmg

cp "$DMG_RELEASE" "$DMG_IMMUTABLE"
