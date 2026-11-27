#!/usr/bin/env bash
# nightly.yml verify-nightly-identity-legacy: "Verify stapled cmux NIGHTLY DMG artifact". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
[[ "$NIGHTLY_BUILD" =~ ^[0-9]+$ ]] || { echo "invalid build '$NIGHTLY_BUILD'" >&2; exit 1; }
[[ "$SIGNED_SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "the signing job recorded no sha256" >&2; exit 1; }
dmg="legacy-signed/${LEGACY_DMG_PREFIX}${NIGHTLY_BUILD}.dmg"
[ -f "$dmg" ] || { echo "no stapled DMG at $dmg" >&2; exit 1; }
stapled_flag=(--require-stapled-app)
if [ -n "${STAPLED_APP_FALLBACK_ID:-}" ]; then
  stapled_flag=(--stapled-app-fallback "$STAPLED_APP_FALLBACK_ID")
fi
./scripts/ci/verify-dmg-artifact.sh "$dmg" nightly --expect-sha256 "$SIGNED_SHA256" "${stapled_flag[@]}" 3>"$RUNNER_TEMP/verified.line"
tested="$(awk '$1 == "verified" {print $2}' "$RUNNER_TEMP/verified.line")"
[ "$tested" = "$SIGNED_SHA256" ] || { echo "verify-dmg-artifact.sh verified '$tested', not the signed $SIGNED_SHA256" >&2; exit 1; }
echo "tested_sha256=$tested" >> "$GITHUB_OUTPUT"
echo "### cmux NIGHTLY-identity build $NIGHTLY_BUILD: DMG $tested statically verified" >> "$GITHUB_STEP_SUMMARY"
