#!/usr/bin/env bash
# nightly.yml sign-nightly-identity-legacy: "Hand the stapled cmux NIGHTLY DMG to the verify job". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# The stapled DMG goes to the secret-free verify job; publish takes it
# only with the sha256 that job tested.
set -euo pipefail
dmg="legacy-out/${LEGACY_DMG_PREFIX}${NIGHTLY_BUILD}.dmg"
[ -f "$dmg" ] || { echo "no stapled DMG at $dmg" >&2; exit 1; }
mkdir -p legacy-signed
cp "$dmg" legacy-signed/
sha="$(shasum -a 256 "legacy-signed/$(basename "$dmg")" | awk '{print $1}')"
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "no sha256 for $dmg" >&2; exit 1; }
minimum="$(python3 scripts/ci/appcast_minimum_system_version.py floor "legacy-app/cmux NIGHTLY.app")"
[[ "$minimum" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "invalid minimum system version '$minimum'" >&2; exit 1; }
{ echo "dmg_sha256=$sha"; echo "minimum_system_version=$minimum"; } >> "$GITHUB_OUTPUT"
echo "signed $(basename "$dmg") sha256 $sha"
