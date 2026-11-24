#!/usr/bin/env bash
# nightly-next-one, behind vars.CMUX_NEXT_PKG_ARTIFACT == '1' (off by default): build the installer package of
# this run's signed app (scripts/cmux-next/pkg/build-pkg.sh, RFD 0134 Table 4 row 1) into next-pkg/, for the
# workflow to keep as a short-lived artifact. It is never published: no feed, release or download names it.
#
# Signed and notarized only when the release environment holds a Developer ID Installer certificate
# (APPLE_INSTALLER_CERTIFICATE_BASE64, APPLE_INSTALLER_CERTIFICATE_PASSWORD, APPLE_INSTALLER_IDENTITY); its own
# keychain lives only for this step. Without one the package is unsigned, for measurement only.
#
# Inputs: CHANNEL_APP_PATH (the signed app, one-job.sh signed), CHANNEL_DMG_PREFIX, NIGHTLY_BUILD,
# PUBLISH_TOOLING (the tooling checkout's scripts/), and ASC_API_* for notarization.
set -euo pipefail

tooling="${PUBLISH_TOOLING:?}"
app="${CHANNEL_APP_PATH:?}"
out="next-pkg/${CHANNEL_DMG_PREFIX:?}-${NIGHTLY_BUILD:-unknown}-arm64.pkg"
args=()

if [ -n "${APPLE_INSTALLER_CERTIFICATE_BASE64:-}" ] && [ -n "${APPLE_INSTALLER_IDENTITY:-}" ]; then
  keychain=cmux-installer.keychain
  trap 'bash "$tooling/ci/signing-keychain.sh" delete --keychain "$keychain" || true' EXIT
  APPLE_CERTIFICATE_BASE64="$APPLE_INSTALLER_CERTIFICATE_BASE64" \
    APPLE_CERTIFICATE_PASSWORD="${APPLE_INSTALLER_CERTIFICATE_PASSWORD:-}" \
    bash "$tooling/ci/signing-keychain.sh" create --keychain "$keychain"
  args=(--sign "$APPLE_INSTALLER_IDENTITY" --keychain "$keychain" --notarize)
else
  echo "::notice title=cmux NEXT pkg::no Developer ID Installer certificate in this environment: the package is unsigned (measurement only)"
fi

rm -rf next-pkg
bash "$tooling/cmux-next/pkg/build-pkg.sh" "$app" "$out" ${args[@]+"${args[@]}"}
shasum -a 256 "$out"
