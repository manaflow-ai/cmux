#!/usr/bin/env bash
# nightly.yml signer-app: "Pack the signed app" for the Mac DMG job (signer-dmg-image), which staples
# the ticket once Apple has accepted these bytes (submit-app.sh submits the same bundle). Its
# Info.plist also goes out on its own (info_sha256), so signer-dmg writes the appcast without
# downloading the whole app.
set -euo pipefail
: "${SIGNER_WORK:?}" "${CHANNEL_APP_NAME:?}"
mkdir -p signer-out
tar -C "$SIGNER_WORK" -cf signer-out/signed-app.tar "$CHANNEL_APP_NAME.app"
sha="$(sha256sum signer-out/signed-app.tar | cut -d' ' -f1)"
echo "sha256=$sha" >> "$GITHUB_OUTPUT"
echo "Signed app tar sha256: $sha" >> "$GITHUB_STEP_SUMMARY"
mkdir -p signer-out/info
cp "$SIGNER_WORK/$CHANNEL_APP_NAME.app/Contents/Info.plist" signer-out/info/Info.plist
echo "info_sha256=$(sha256sum signer-out/info/Info.plist | cut -d' ' -f1)" >> "$GITHUB_OUTPUT"
