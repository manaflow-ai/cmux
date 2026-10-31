#!/usr/bin/env bash
# nightly.yml verify-final-dmg-nightly: "Verify final DMG artifact". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
mkdir -p tested
: > "tested/tested-${NIGHTLY_VARIANT}.sha256"
release="final-dmg/${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}.dmg"
[ -f "$release" ] || { echo "no final DMG for $NIGHTLY_VARIANT" >&2; exit 1; }
# The DMG was signed and checked for the signing channel (cmux NEXT signs as next).
stapled_flag=(--require-stapled-app)
if [ -n "${STAPLED_APP_FALLBACK_ID:-}" ]; then
  stapled_flag=(--stapled-app-fallback "$STAPLED_APP_FALLBACK_ID")
fi
# signer-dmg's one-DMG artifact carries no immutable copy, which signer-dmg.sh makes with
# cp: make it the same way. publish-nightly publishes that name only with these bytes.
if [ "$POOL_SIGNED" = true ]; then
  immutable="final-dmg/${CHANNEL_DMG_PREFIX}-${NIGHTLY_VARIANT}-${NIGHTLY_BUILD:?}.dmg"
  [ ! -e "$immutable" ] || { echo "the one-DMG artifact holds $(basename "$immutable")" >&2; exit 1; }
  cp -c "$release" "$immutable" 2>/dev/null || cp "$release" "$immutable"
fi
./scripts/ci/verify-dmg-artifact.sh "$release" "$SIGN_CHANNEL" "${stapled_flag[@]}" 3>"$RUNNER_TEMP/verified.line"
tested="$(awk '$1 == "verified" {print $2}' "$RUNNER_TEMP/verified.line")"
[ -n "$tested" ] || { echo "verify-dmg-artifact.sh reported no verified digest" >&2; exit 1; }
# The immutable DMG is a copy of the release DMG: require the same bytes.
for dmg in final-dmg/"${CHANNEL_DMG_PREFIX}"-*.dmg; do
  [ -f "$dmg" ] || continue
  actual="$(shasum -a 256 "$dmg" | awk '{print $1}')"
  [ "$actual" = "$tested" ] || { echo "$(basename "$dmg") differs from the DMG that was verified" >&2; exit 1; }
  printf '%s  %s\n' "$actual" "$(basename "$dmg")" >> "tested/tested-${NIGHTLY_VARIANT}.sha256"
done
cat "tested/tested-${NIGHTLY_VARIANT}.sha256"
