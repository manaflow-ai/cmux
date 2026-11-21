#!/usr/bin/env bash
# Make a cmux NIGHTLY-identity build of a cmux NEXT DEV app on Linux (cmux-next-dev-daily.yml,
# job nightly-commit-sign).
#
#   scripts/ci/nightly-commit-identity.sh <dev-app> <build> <version> <out-dir>
#
# The model is feat-cmux-next's scripts/ci/nightly-next-legacy-identity.sh, which turns a notarized
# cmux NEXT app into cmux NIGHTLY on a Mac; this does the same to the unsigned DEV Release app of a
# feat-cmux-next source run, on Linux with our rcodesign, as the DEV sign job does:
# Info.plist (scripts/ci/nightly_commit_build.py identity: name, bundle id com.cmuxterm.app.nightly,
# auth URL scheme cmux-nightly, no CMUX_AUTH_CALLBACK_SCHEME, the nightly-next feed and key, build and
# marketing version; CMUXCommit stays), the NIGHTLY Developer ID profile, then the whole bundle inside
# out (scripts/ci/rcodesign-sign-bundle-dev.sh, which mirrors scripts/sign-cmux-bundle.sh with
# CMUX_SIGN_MODE=all) with cmux.nightly.entitlements less the tunnel keys feat-cmux-next's copy dropped.
# The Mac job (nightly-commit-dmg-build) then runs codesign --verify --deep --strict, checks the signed
# application-identifier and keychain group with codesign -d, and runs
# scripts/verify-app-bundle-channel-metadata.sh <app> nightly, as the legacy script does at its end.
#
# Env: NIGHTLY_PROFILE_PATH (decoded APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64), FEED_URL (SUFeedURL),
# SPARKLE_PUBLIC_KEY (SUPublicEDKey), NIGHTLY_ICONSET (the source commit's
# Assets.xcassets/AppIcon-Nightly.appiconset), and rcodesign-sign-bundle-dev.sh's APPLE_CERTIFICATE_BASE64,
# APPLE_CERTIFICATE_PASSWORD, APPLE_SIGNING_IDENTITY and RCODESIGN.
#
# Writes "<out-dir>/cmux NIGHTLY.app", signed and not notarized (the DMG is notarized and stapled).
set -euo pipefail

[[ $# -eq 4 ]] || { echo "usage: $0 <dev-app> <build> <version> <out-dir>" >&2; exit 2; }
DEV_APP="${1%/}" BUILD="$2" VERSION="$3" OUT_DIR="$4"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
: "${NIGHTLY_PROFILE_PATH:?}" "${FEED_URL:?}" "${SPARKLE_PUBLIC_KEY:?}" "${NIGHTLY_ICONSET:?}"
HELPER="$ROOT_DIR/scripts/ci/nightly_commit_build.py"
NAME="cmux NIGHTLY"

[[ -d "$DEV_APP/Contents" ]] || { echo "error: no app at $DEV_APP" >&2; exit 1; }
[[ -f "$NIGHTLY_PROFILE_PATH" ]] || { echo "error: no NIGHTLY profile at $NIGHTLY_PROFILE_PATH" >&2; exit 1; }
mkdir -p "$OUT_DIR"
app="$OUT_DIR/$NAME.app"
[[ ! -e "$app" ]] || { echo "error: $app exists" >&2; exit 1; }
# A move, not a copy: the unpacked DEV app is this job's own, and a copy on Linux could lose links.
mv "$DEV_APP" "$app"

python3 -I "$HELPER" identity "$app/Contents/Info.plist" "$BUILD" "$FEED_URL" "$SPARKLE_PUBLIC_KEY" "$VERSION"
# The nightly compiles with ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-Nightly; the DEV compile only has
# AppIcon. The source commit's own appiconset becomes Resources/AppIcon-Nightly.icns (CFBundleIconFile).
python3 -I "$HELPER" icns "$NIGHTLY_ICONSET" "$app/Contents/Resources/AppIcon-Nightly.icns"
chmod 644 "$app/Contents/Resources/AppIcon-Nightly.icns"
python3 -I "$HELPER" channel "$app"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The NIGHTLY Developer ID profile for this exact App ID (openssl unwraps what security cms -D does).
openssl cms -verify -noverify -inform DER -in "$NIGHTLY_PROFILE_PATH" -out "$work/profile.plist" 2>/dev/null ||
  { echo "error: the NIGHTLY profile is not a CMS-signed provisioning profile" >&2; exit 1; }
python3 -I "$HELPER" profile "$work/profile.plist"
cp "$NIGHTLY_PROFILE_PATH" "$app/Contents/embedded.provisionprofile"
chmod 644 "$app/Contents/embedded.provisionprofile"

python3 -I "$HELPER" entitlements "$ROOT_DIR/cmux.nightly.entitlements" "$work/app.entitlements"
CMUX_SIGN_MODE=all CMUX_HELPER_ENTITLEMENTS="$ROOT_DIR/cmux-helper.entitlements" \
  "$ROOT_DIR/scripts/ci/rcodesign-sign-bundle-dev.sh" "$app" "$work/app.entitlements"

# The keychain sign-in survives only with the same App ID and keychain group: read them back from the
# main executable's signature.
exe="$(python3 -I -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleExecutable"])' "$app/Contents/Info.plist")"
"${RCODESIGN:-rcodesign}" print-signature-info --config-file /dev/null "$app/Contents/MacOS/$exe" > "$work/signature.txt"
for want in "<key>com.apple.application-identifier</key>" "<string>7WLXT3NR37.com.cmuxterm.app.nightly</string>" \
            "<key>keychain-access-groups</key>"; do
  grep -qF -- "$want" "$work/signature.txt" || { echo "error: the signed app's entitlements lack $want" >&2; exit 1; }
done
echo "cmux NIGHTLY-identity build $BUILD ($VERSION): $app"
