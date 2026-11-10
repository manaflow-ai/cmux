#!/usr/bin/env bash
# nightly.yml legacy-signer-dmg: "Hand the stapled cmux NIGHTLY DMG to the verify job", as the macOS
# legacy signer's legacy-identity-sign-hand-to-verify.sh does: the DMG under its release asset name in
# legacy-signed/, its sha256 and the app's macOS floor (from the image job) for the appcast. The outputs
# are the ones publish-nightly-identity-legacy reads from that job, written only here, last.
set -euo pipefail
: "${NIGHTLY_BUILD:?}" "${LEGACY_DMG_PREFIX:?}" "${FLOOR:?}" "${BUILD_SHA:?}"
name="${LEGACY_DMG_PREFIX}${NIGHTLY_BUILD}.dmg"
[ -f "signer-out/$name" ] || { echo "no stapled DMG at signer-out/$name" >&2; exit 1; }
[[ "$FLOOR" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "invalid minimum system version '$FLOOR'" >&2; exit 1; }
[[ "$BUILD_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid build commit '$BUILD_SHA'" >&2; exit 1; }
mkdir -p legacy-signed
mv "signer-out/$name" legacy-signed/
sha="$(sha256sum "legacy-signed/$name" | cut -d' ' -f1)"
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "no sha256 for $name" >&2; exit 1; }
{
  echo "dmg_sha256=$sha"
  echo "minimum_system_version=$FLOOR"
  echo "build_sha=$BUILD_SHA"
} >> "$GITHUB_OUTPUT"
echo "### cmux NIGHTLY-identity build $NIGHTLY_BUILD signed by the release signer: $name sha256 $sha" >> "$GITHUB_STEP_SUMMARY"
