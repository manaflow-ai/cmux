#!/usr/bin/env bash
# nightly.yml launch-smoke-nightly: "Check the DMG is the one signer-dmg signs". The unsigned DMG
# signer-dmg-image uploaded must have the digest signer-dmg checks before it signs (UNSIGNED_SHA256);
# its image digest (dmg_image_digest.py: the bytes signing and stapling leave alone) goes to the job's
# output, and publish-nightly requires the final DMG's to equal it.
set -euo pipefail
: "${DMG:?}" "${UNSIGNED_SHA256:?}"
ci="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$DMG" ] || { echo "no unsigned DMG at $DMG" >&2; exit 1; }
actual="$(shasum -a 256 "$DMG" | awk '{print $1}')"
[ "$actual" = "$UNSIGNED_SHA256" ] || { echo "::error::$DMG is $actual, not the $UNSIGNED_SHA256 signer-dmg signs" >&2; exit 1; }
image="$(python3 -I "$ci/dmg_image_digest.py" "$DMG")"
echo "image=$image" >> "$GITHUB_OUTPUT"
echo "Launch smoke image: unsigned DMG $actual, image $image" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
