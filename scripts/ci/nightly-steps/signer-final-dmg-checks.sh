#!/usr/bin/env bash
# nightly.yml verify-final-dmg-nightly: "Apple's checks of a pool-signed DMG
# and the app in it". The DMG signer-dmg signed and notarized: its signature,
# Gatekeeper's notarized source, Apple's checks of the app inside
# (signer-apple-checks.sh: stapler, spctl, syspolicy_check and the copied
# Computer Use helper), and the appcast's Sparkle signature against the pinned
# key. "Verify final DMG artifact" has already checked the staples and the bytes.
set -euo pipefail
: "${CHANNEL_DMG_PREFIX:?}" "${NIGHTLY_VARIANT:?}" "${CHANNEL_APP_NAME:?}" "${NIGHTLY_BUILD:?}" "${NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY:?}"
dmg="final-dmg/${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}.dmg"
immutable="final-dmg/${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}-${NIGHTLY_BUILD}.dmg"
/usr/bin/codesign --verify --verbose=2 "$dmg"
spctl -a -vv -t open --context context:primary-signature "$dmg" 2>&1 | tee "$RUNNER_TEMP/spctl-dmg.txt"
grep -qx 'source=Notarized Developer ID' "$RUNNER_TEMP/spctl-dmg.txt"
python3 -I scripts/ci/release-signer/verify_appcast_item.py "final-dmg/appcast-${NIGHTLY_VARIANT}.xml" \
  "$immutable" "$NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY" "$NIGHTLY_BUILD" | tee -a "$GITHUB_STEP_SUMMARY"
mnt="$(mktemp -d)"
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mnt" >/dev/null
trap 'hdiutil detach "$mnt" >/dev/null 2>&1 || hdiutil detach -force "$mnt" >/dev/null 2>&1 || true' EXIT
bash scripts/ci/nightly-steps/signer-apple-checks.sh "$mnt/$CHANNEL_APP_NAME.app"
