#!/usr/bin/env bash
# nightly.yml signer-app: "Pack the stapled app" for the Mac DMG job.
set -euo pipefail
: "${SIGNER_WORK:?}" "${CHANNEL_APP_NAME:?}"
mkdir -p signer-out
tar -C "$SIGNER_WORK" -cf signer-out/stapled-app.tar "$CHANNEL_APP_NAME.app"
sha="$(sha256sum signer-out/stapled-app.tar | cut -d' ' -f1)"
echo "sha256=$sha" >> "$GITHUB_OUTPUT"
echo "Stapled app tar sha256: $sha (app submission $APP_SUBMISSION)" >> "$GITHUB_STEP_SUMMARY"
