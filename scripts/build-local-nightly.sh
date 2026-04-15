#!/usr/bin/env bash
# Build a locally-signed "cmux NIGHTLY" app that carries the real
# Developer ID signature and an embedded provisioning profile. This is
# required to exercise entitlements like
# com.apple.developer.web-browser.public-key-credential (Passkey /
# WebAuthn) which refuse to run on ad-hoc signed DEV builds.
#
# Produces: build-local-nightly/Build/Products/Release/cmux NIGHTLY.app
#
# Env overrides:
#   CMUX_NIGHTLY_PROFILE    path to nightly .provisionprofile
#                           (default: ~/.secrets/cmuxterm/cmux_nightly_Developer_ID.provisionprofile)
#   CMUX_SIGNING_IDENTITY   codesign identity
#                           (default: "Developer ID Application: Manaflow, Inc. (7WLXT3NR37)")
#   CMUX_NIGHTLY_ARCHS      "arm64" (default) or "arm64 x86_64" for universal
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${CMUX_NIGHTLY_PROFILE:-$HOME/.secrets/cmuxterm/cmux_nightly_Developer_ID.provisionprofile}"
IDENTITY="${CMUX_SIGNING_IDENTITY:-Developer ID Application: Manaflow, Inc. (7WLXT3NR37)}"
ARCHS="${CMUX_NIGHTLY_ARCHS:-arm64}"
ENTITLEMENTS="$REPO_ROOT/cmux.entitlements"
BUILD_DIR="$REPO_ROOT/build-local-nightly"

if [[ ! -f "$PROFILE" ]]; then
  echo "error: provisioning profile not found at $PROFILE" >&2
  echo "  download from https://developer.apple.com/account/resources/profiles/list" >&2
  exit 1
fi

if ! /usr/bin/security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "error: signing identity not found in keychain: $IDENTITY" >&2
  exit 1
fi

TMP_PLIST="$(mktemp -t cmux-profile.XXXXXX.plist)"
trap 'rm -f "$TMP_PLIST"' EXIT
/usr/bin/security cms -D -i "$PROFILE" > "$TMP_PLIST"
PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$TMP_PLIST")"
if [[ "$PROFILE_APP_ID" != "7WLXT3NR37.com.cmuxterm.app.nightly" ]]; then
  echo "error: profile targets unexpected app id: $PROFILE_APP_ID" >&2
  exit 1
fi

cd "$REPO_ROOT"

echo "==> Building Release with DEBUG conditionals ($ARCHS) into $BUILD_DIR"
xcodebuild -scheme cmux -configuration Release -derivedDataPath "$BUILD_DIR" \
  -destination 'generic/platform=macOS' \
  ARCHS="$ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-Nightly \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG" \
  GCC_PREPROCESSOR_DEFINITIONS="DEBUG=1 \$(inherited)" \
  build

APP_DIR="$BUILD_DIR/Build/Products/Release"
SRC_APP="$APP_DIR/cmux.app"
DEST_APP="$APP_DIR/cmux NIGHTLY local.app"

if [[ ! -d "$SRC_APP" ]]; then
  echo "error: cmux.app not found at $SRC_APP" >&2
  exit 1
fi

rm -rf "$DEST_APP"

echo "==> Rewriting Info.plist for nightly bundle"
PL="$SRC_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName cmux NIGHTLY local" "$PL"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName cmux NIGHTLY local" "$PL"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.cmuxterm.app.nightly" "$PL"
/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$PL" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$PL" >/dev/null 2>&1 || true

mv "$SRC_APP" "$DEST_APP"

echo "==> Embedding provisioning profile"
cp "$PROFILE" "$DEST_APP/Contents/embedded.provisionprofile"

echo "==> Composing per-bundle entitlements (cmux.entitlements + application-identifier)"
# AuthenticationServices refuses restricted entitlements like WebAuthn
# with error 1004 unless the signed entitlements carry a valid
# application-identifier that matches the embedded provisioning
# profile. The checked-in cmux.entitlements omits it because it's
# bundle-id specific; inject it here for the nightly bundle.
NIGHTLY_ENT="$(mktemp -t cmux-nightly-ent.XXXXXX.plist)"
trap 'rm -f "$TMP_PLIST" "$NIGHTLY_ENT"' EXIT
cp "$ENTITLEMENTS" "$NIGHTLY_ENT"
/usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier" "$NIGHTLY_ENT" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.team-identifier" "$NIGHTLY_ENT" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string 7WLXT3NR37.com.cmuxterm.app.nightly" "$NIGHTLY_ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string 7WLXT3NR37" "$NIGHTLY_ENT"

echo "==> Codesigning helpers and app"
CLI_PATH="$DEST_APP/Contents/Resources/bin/cmux"
HELPER_PATH="$DEST_APP/Contents/Resources/bin/ghostty"

if [[ -f "$CLI_PATH" ]]; then
  /usr/bin/codesign --force --options runtime --timestamp=none \
    --sign "$IDENTITY" --entitlements "$NIGHTLY_ENT" "$CLI_PATH"
fi
if [[ -f "$HELPER_PATH" ]]; then
  /usr/bin/codesign --force --options runtime --timestamp=none \
    --sign "$IDENTITY" --entitlements "$NIGHTLY_ENT" "$HELPER_PATH"
fi

/usr/bin/codesign --force --options runtime --timestamp=none \
  --sign "$IDENTITY" --entitlements "$NIGHTLY_ENT" --deep "$DEST_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$DEST_APP"

echo "==> Verifying WebAuthn entitlement present after signing"
if ! /usr/bin/codesign -d --entitlements :- "$DEST_APP" 2>&1 \
    | grep -q "com.apple.developer.web-browser.public-key-credential"; then
  echo "error: WebAuthn entitlement missing from signed binary" >&2
  exit 1
fi

echo
echo "App path:"
echo "  $DEST_APP"
