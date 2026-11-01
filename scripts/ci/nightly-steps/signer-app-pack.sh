#!/usr/bin/env bash
# nightly.yml signer-app: "Pack the signed app" for signer-app-notary (Apple's notarization) and
# the Mac DMG job (signer-dmg-image), which staples the ticket once Apple has accepted these bytes.
set -euo pipefail
: "${SIGNER_WORK:?}" "${CHANNEL_APP_NAME:?}"
mkdir -p signer-out
tar -C "$SIGNER_WORK" -cf signer-out/signed-app.tar "$CHANNEL_APP_NAME.app"
sha="$(sha256sum signer-out/signed-app.tar | cut -d' ' -f1)"
echo "sha256=$sha" >> "$GITHUB_OUTPUT"
echo "Signed app tar sha256: $sha" >> "$GITHUB_STEP_SUMMARY"
