#!/usr/bin/env bash
# nightly.yml signer-dmg: "Sign, notarize and staple the DMG" with the release
# signer (scripts/ci/release-signer/notarize-dmg.sh), then the immutable copy,
# as notarize-nightly-dmg.sh leaves them.
set -euo pipefail
: "${TOOLS:?}" "${NIGHTLY_DMG_RELEASE:?}" "${NIGHTLY_DMG_IMMUTABLE:?}" "${UNSIGNED_SHA256:?}"
TOOLS="$(cd "$TOOLS" && pwd)"
cd signer-out
if command -v sha256sum >/dev/null 2>&1; then
  echo "$UNSIGNED_SHA256  $NIGHTLY_DMG_RELEASE" | sha256sum -c -
else
  actual="$(shasum -a 256 "$NIGHTLY_DMG_RELEASE" | awk '{print $1}')"
  [ "$actual" = "$UNSIGNED_SHA256" ] || { echo "unsigned DMG digest mismatch" >&2; exit 1; }
fi
bash "$TOOLS/scripts/ci/release-signer/notarize-dmg.sh" "$NIGHTLY_DMG_RELEASE" 2>&1 | tee notary-dmg.log
id="$(grep -oiE 'submission id:? *[0-9a-f-]{36}' notary-dmg.log | grep -oE '[0-9a-f-]{36}' | head -n 1 || true)"
cp "$NIGHTLY_DMG_RELEASE" "$NIGHTLY_DMG_IMMUTABLE"
echo "submission_id=$id" >> "$GITHUB_OUTPUT"
echo "DMG notarization: Accepted, submission $id" >> "$GITHUB_STEP_SUMMARY"
