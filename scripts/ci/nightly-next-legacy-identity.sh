#!/usr/bin/env bash
# Make a cmux NIGHTLY-identity copy of a published cmux NEXT build (cx-x7hwx).
#
# Before cmux NEXT (b9ac67887fa7, 2026-10-12) the nightly-next track shipped as
# cmux NIGHTLY (com.cmuxterm.app.nightly) on the feed
# NIGHTLY_NEXT_LEGACY_FEED_BASE. Those installs keep their terminals, agent
# sessions, keychain sign-in, browser data and preferences under that bundle id,
# and Sparkle installs only an update with the same bundle id or file name. So
# nightly.yml (job publish-nightly-identity-legacy) gives them every new build
# under their own identity: this script turns the notarized cmux NEXT app into
# the same build signed as cmux NIGHTLY, exactly as build 3821558930001 was
# signed (cmux.nightly.entitlements, the NIGHTLY Developer ID profile, keychain
# group 7WLXT3NR37.com.cmuxterm.app.nightly). The Sparkle key does not change.
#
# Usage:
#   scripts/ci/nightly-next-legacy-identity.sh <next-dmg> <build> <out-dir>
#
# Environment:
#   APPLE_SIGNING_IDENTITY       Developer ID identity (build.keychain)
#   NIGHTLY_PROFILE_PATH         decoded APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64
#   LEGACY_FEED_URL              SUFeedURL of the result (the old appcast-arm64.xml)
#   EXPECTED_SPARKLE_PUBLIC_KEY  SUPublicEDKey the NEXT app must carry, unchanged
#
# Writes "<out-dir>/cmux NIGHTLY.app", signed and not yet notarized.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <next-dmg> <build> <out-dir>" >&2
  exit 2
fi
NEXT_DMG="$1"
BUILD="$2"
OUT_DIR="$3"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
: "${APPLE_SIGNING_IDENTITY:?}" "${NIGHTLY_PROFILE_PATH:?}" "${LEGACY_FEED_URL:?}" "${EXPECTED_SPARKLE_PUBLIC_KEY:?}"

NEXT_ID="com.cmuxterm.app.nightly.cmux-next"
LEGACY_ID="com.cmuxterm.app.nightly"
LEGACY_NAME="cmux NIGHTLY"
LEGACY_SCHEME="cmux-nightly"
LEGACY_ENTITLEMENTS="$ROOT_DIR/cmux.nightly.entitlements"
TEAM_ID="7WLXT3NR37"

mount_dir="$(mktemp -d)"
cleanup() {
  hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1 || hdiutil detach -force "$mount_dir" >/dev/null 2>&1 || true
  rmdir "$mount_dir" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil attach "$NEXT_DMG" -nobrowse -readonly -mountpoint "$mount_dir" -quiet
next_app="$mount_dir/cmux NEXT.app"
[[ -d "$next_app" ]] || { echo "no cmux NEXT.app in $NEXT_DMG" >&2; exit 1; }

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
[[ "$(plist_get "$next_app" CFBundleIdentifier)" == "$NEXT_ID" ]] || { echo "input is not cmux NEXT" >&2; exit 1; }
[[ "$(plist_get "$next_app" CFBundleVersion)" == "$BUILD" ]] || { echo "input is not build $BUILD" >&2; exit 1; }
[[ "$(plist_get "$next_app" SUPublicEDKey)" == "$EXPECTED_SPARKLE_PUBLIC_KEY" ]] || { echo "input SUPublicEDKey is not the track key" >&2; exit 1; }
codesign --verify --deep --strict "$next_app"

mkdir -p "$OUT_DIR"
app="$OUT_DIR/$LEGACY_NAME.app"
rm -rf "$app"
ditto "$next_app" "$app"
cleanup
trap - EXIT

# Identity: the values prepare_variant (nightly.yml) wrote for nightly-next
# before b9ac67887fa7. Version, commit and SUPublicEDKey stay as built.
info="$app/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "$1" "$info"; }
pb "Set :CFBundleName $LEGACY_NAME"
pb "Set :CFBundleDisplayName $LEGACY_NAME"
pb "Set :CFBundleIdentifier $LEGACY_ID"
url_type_name="$(pb "Print :CFBundleURLTypes:1:CFBundleURLName")"
[[ "$url_type_name" == *.auth ]] || { echo "CFBundleURLTypes[1] is not the auth URL type: $url_type_name" >&2; exit 1; }
pb "Set :CFBundleURLTypes:1:CFBundleURLSchemes:0 $LEGACY_SCHEME"
# cmux NIGHTLY signs in through cmux-nightly (CloudConfiguration.defaultScheme);
# drop cmux NEXT's override.
pb "Delete :LSEnvironment:CMUX_AUTH_CALLBACK_SCHEME" >/dev/null 2>&1 || true
pb "Set :SUFeedURL $LEGACY_FEED_URL"

# A stapled ticket names the old CDHash; the notarization below staples a new one.
rm -f "$app/Contents/CodeResources"

# Profile: the NIGHTLY Developer ID profile for this exact App ID.
profile_plist="$(mktemp)"
security cms -D -i "$NIGHTLY_PROFILE_PATH" > "$profile_plist"
profile_app_id="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$profile_plist")"
[[ "$profile_app_id" == "$TEAM_ID.$LEGACY_ID" ]] || { echo "NIGHTLY profile targets $profile_app_id" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c "Print :ProvisionsAllDevices" "$profile_plist")" == true ]] || { echo "NIGHTLY profile is not Developer ID" >&2; exit 1; }
rm -f "$profile_plist"
cp "$NIGHTLY_PROFILE_PATH" "$app/Contents/embedded.provisionprofile"

# Whole bundle, inside out, as for every channel: launchd plists re-stamped from
# the new bundle id, CLI and helpers, SSH payloads (re-pinned), plugins, the
# Chromium engine, frameworks, then the app with cmux.nightly.entitlements.
# The Computer Use helper (com.cmuxterm.cua, own ticket stapled) is kept as
# notarized: its identity does not depend on the host's.
CMUX_SIGN_MODE=all-except-computer-use "$ROOT_DIR/scripts/sign-cmux-bundle.sh" \
  "$app" "$LEGACY_ENTITLEMENTS" "$APPLE_SIGNING_IDENTITY"
"$ROOT_DIR/scripts/ci/verify-computer-use-helper.sh" signed "$app"

# The keychain sign-in survives only with the same App ID and keychain group.
signed="$(mktemp)"
codesign -d --entitlements :- "$app" 2>/dev/null > "$signed"
[[ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.application-identifier" "$signed")" == "$TEAM_ID.$LEGACY_ID" ]] \
  || { echo "signed app has the wrong application-identifier" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c "Print :keychain-access-groups:0" "$signed")" == "$TEAM_ID.$LEGACY_ID" ]] \
  || { echo "signed app has the wrong keychain access group" >&2; exit 1; }
rm -f "$signed"
codesign --verify --deep --strict --verbose=2 "$app"
"$ROOT_DIR/scripts/verify-app-bundle-channel-metadata.sh" "$app" nightly
echo "cmux NIGHTLY-identity build $BUILD: $app"
