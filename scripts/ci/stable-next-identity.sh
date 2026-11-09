#!/usr/bin/env bash
# Make the cmux NEXT Stable copy of a published cmux NEXT nightly build (stable-next.yml).
#
# Stable ships the exact bits the nightly shipped, under its own identity, so the gates that ran on
# the nightly's commit and the launch smokes of the signed copy describe what installs get:
#   name        cmux NEXT Stable
#   bundle id   com.cmuxterm.app.nightly.cmux-next-stable (a nightly-kind id: BuildIdentity gives it
#               nightly behaviour with roots of its own; com.cmuxterm.app.<other> would be a DEV build)
#   URL scheme  cmux-next-stable (sign-in callback; web/app/lib/native-callback.ts allows it)
#   feed        STABLE_FEED_URL (.../nightly-next/stable/appcast-arm64.xml)
#   icon        the regular cmux icon (Assets.xcassets/AppIcon.appiconset as AppIcon.icns), not the
#               Nightly one
# Version, commit and SUPublicEDKey stay as built. Entitlements: cmux.next-dev.entitlements, as the
# nightly (no restricted entitlement, so no provisioning profile).
#
# Usage:
#   scripts/ci/stable-next-identity.sh <next-dmg> <build> <out-dir>
#
# Environment:
#   APPLE_SIGNING_IDENTITY       Developer ID identity (build.keychain), or "-" for an ad-hoc dry run
#   STABLE_FEED_URL              SUFeedURL of the result
#   EXPECTED_SPARKLE_PUBLIC_KEY  SUPublicEDKey the NEXT app must carry, unchanged
#   EXPECTED_COMMIT              the 40-hex commit the stable gates tested; the bundle's CMUXCommit
#                                must be its prefix, so no gate vouches for another commit
#   ICON_SOURCE                  optional: the appiconset to build AppIcon.icns from
#
# Writes "<out-dir>/cmux NEXT Stable.app", signed and not yet notarized.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <next-dmg> <build> <out-dir>" >&2
  exit 2
fi
NEXT_DMG="$1"
BUILD="$2"
OUT_DIR="$3"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
: "${APPLE_SIGNING_IDENTITY:?}" "${STABLE_FEED_URL:?}" "${EXPECTED_SPARKLE_PUBLIC_KEY:?}" "${EXPECTED_COMMIT:?}"
[[ "$EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "EXPECTED_COMMIT must be a 40-hex commit: $EXPECTED_COMMIT" >&2; exit 1; }
ICON_SOURCE="${ICON_SOURCE:-$ROOT_DIR/Assets.xcassets/AppIcon.appiconset}"

NEXT_ID="com.cmuxterm.app.nightly.cmux-next"
STABLE_ID="com.cmuxterm.app.nightly.cmux-next-stable"
STABLE_NAME="cmux NEXT Stable"
STABLE_SCHEME="cmux-next-stable"
STABLE_ICON="AppIcon"
ENTITLEMENTS="$ROOT_DIR/cmux.next-dev.entitlements"
TEAM_ID="7WLXT3NR37"

case "$STABLE_FEED_URL" in
  https://*/nightly-next/stable/appcast-arm64.xml) ;;
  *) echo "STABLE_FEED_URL must be an https .../nightly-next/stable/appcast-arm64.xml URL: $STABLE_FEED_URL" >&2; exit 1 ;;
esac

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
commit="$(plist_get "$next_app" CMUXCommit)"
[[ "$commit" =~ ^[0-9a-f]{7,40}$ && "$EXPECTED_COMMIT" == "$commit"* ]] \
  || { echo "input was built from CMUXCommit '$commit', not the gated commit $EXPECTED_COMMIT" >&2; exit 1; }
codesign --verify --deep --strict "$next_app"
team="$(codesign -dv "$next_app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$team" == "$TEAM_ID" ]] || { echo "input is signed by team '$team', not $TEAM_ID" >&2; exit 1; }

mkdir -p "$OUT_DIR"
app="$OUT_DIR/$STABLE_NAME.app"
rm -rf "$app"
ditto "$next_app" "$app"
cleanup
trap - EXIT

info="$app/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "$1" "$info"; }
pb "Set :CFBundleName $STABLE_NAME"
pb "Set :CFBundleDisplayName $STABLE_NAME"
pb "Set :CFBundleIdentifier $STABLE_ID"
url_type_name="$(pb "Print :CFBundleURLTypes:1:CFBundleURLName")"
[[ "$url_type_name" == *.auth ]] || { echo "CFBundleURLTypes[1] is not the auth URL type: $url_type_name" >&2; exit 1; }
pb "Set :CFBundleURLTypes:1:CFBundleURLName $STABLE_ID.auth"
pb "Set :CFBundleURLTypes:1:CFBundleURLSchemes:0 $STABLE_SCHEME"
pb "Set :LSEnvironment:CMUX_AUTH_CALLBACK_SCHEME $STABLE_SCHEME" >/dev/null 2>&1 \
  || pb "Add :LSEnvironment:CMUX_AUTH_CALLBACK_SCHEME string $STABLE_SCHEME"
pb "Set :SUFeedURL $STABLE_FEED_URL"

# The regular cmux icon. The nightly's asset catalog holds only AppIcon-Nightly, so the icon comes
# from AppIcon.icns: with no AppIcon in Assets.car, macOS falls back to CFBundleIconFile.
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  cp "$ICON_SOURCE/$size.png" "$iconset/icon_${size}x${size}.png"
  cp "$ICON_SOURCE/$size@2x.png" "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/$STABLE_ICON.icns"
rm -rf "$(dirname "$iconset")"
pb "Set :CFBundleIconFile $STABLE_ICON"
pb "Set :CFBundleIconName $STABLE_ICON" >/dev/null 2>&1 || pb "Add :CFBundleIconName string $STABLE_ICON"

# A stapled ticket names the old CDHash; the notarization staples a new one.
rm -f "$app/Contents/CodeResources"

# Whole bundle, inside out, as the nightly-identity copy does (nightly-next-legacy-identity.sh):
# launchd plists re-stamped from the new bundle id, helpers, SSH payloads, plugins, the Chromium
# engine, frameworks, then the app. The Computer Use helper keeps its own notarized signature.
timestamp=()
[[ "$APPLE_SIGNING_IDENTITY" == "-" ]] && timestamp=(CMUX_TIMESTAMP=none)
env ${timestamp[@]+"${timestamp[@]}"} CMUX_SIGN_MODE=all-except-computer-use \
  "$ROOT_DIR/scripts/sign-cmux-bundle.sh" "$app" "$ENTITLEMENTS" "$APPLE_SIGNING_IDENTITY"
if [[ "$APPLE_SIGNING_IDENTITY" != "-" ]]; then
  "$ROOT_DIR/scripts/ci/verify-computer-use-helper.sh" signed "$app"
fi

[[ "$(plist_get "$app" CFBundleIdentifier)" == "$STABLE_ID" ]] || { echo "signed app has the wrong bundle id" >&2; exit 1; }
[[ "$(plist_get "$app" CFBundleVersion)" == "$BUILD" ]] || { echo "signed app is not build $BUILD" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$app"
"$ROOT_DIR/scripts/verify-app-bundle-channel-metadata.sh" "$app" next-stable
echo "cmux NEXT Stable build $BUILD: $app"
