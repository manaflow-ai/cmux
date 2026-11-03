#!/usr/bin/env bash
# nightly.yml legacy-signer-dmg-image: "The cmux NIGHTLY identity of the stapled app". The checks
# scripts/ci/nightly-next-legacy-identity.sh makes on a Mac after it signs, made on the release signer's
# output (it has no codesign -d): the keychain sign-in survives only with the same App ID and keychain
# group, and the bundle carries cmux NIGHTLY's name, bundle id and icon. No secret in this job.
set -euo pipefail
app="${1:?usage: legacy-pool-check-app.sh <app>}"
app="${app%/}"
: "${NIGHTLY_BUILD:?}"
want="7WLXT3NR37.com.cmuxterm.app.nightly"
signed="$(mktemp)"
/usr/bin/codesign -d --entitlements :- "$app" 2>/dev/null > "$signed"
[[ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.application-identifier" "$signed")" == "$want" ]] \
  || { echo "signed app has the wrong application-identifier" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c "Print :keychain-access-groups:0" "$signed")" == "$want" ]] \
  || { echo "signed app has the wrong keychain access group" >&2; exit 1; }
rm -f "$signed"
[[ -f "$app/Contents/embedded.provisionprofile" ]] || { echo "no embedded NIGHTLY profile" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" == "$NIGHTLY_BUILD" ]] \
  || { echo "the app is not build $NIGHTLY_BUILD" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")" == "$NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY" ]] \
  || { echo "the app's SUPublicEDKey is not the track key" >&2; exit 1; }
./scripts/verify-app-bundle-channel-metadata.sh "$app" nightly
echo "cmux NIGHTLY identity of build $NIGHTLY_BUILD checked: $want"
