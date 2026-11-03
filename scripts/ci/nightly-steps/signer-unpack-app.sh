#!/usr/bin/env bash
# nightly.yml signer-dmg-image: "Unpack the signed app". Checks
# signer-app/signed-app.tar against the digest signer-app printed (APP_SHA256), then unpacks it
# into SIGNER_WORK, so the Mac staples the bytes signer-app submitted to Apple.
set -euo pipefail
: "${APP_SHA256:?}" "${SIGNER_WORK:?}"
if command -v sha256sum >/dev/null 2>&1; then sum=(sha256sum); else sum=(shasum -a 256); fi
echo "$APP_SHA256  signer-app/signed-app.tar" | "${sum[@]}" -c -
mkdir -p "$SIGNER_WORK"
tar -C "$SIGNER_WORK" -xf signer-app/signed-app.tar
