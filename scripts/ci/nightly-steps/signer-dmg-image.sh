#!/usr/bin/env bash
# nightly.yml signer-dmg-image: "Build the unsigned DMG". The DMG
# notarize-nightly-dmg.sh packages (create-dmg, then LZMA), around the app the
# release runner pool notarized and stapled; signer-dmg signs and notarizes it.
# This job holds no secret.
set -euo pipefail
: "${SIGNER_WORK:?}" "${CHANNEL_APP_NAME:?}" "${NIGHTLY_DMG_RELEASE:?}" "${CREATE_DMG_VERSION:?}"
app="$SIGNER_WORK/$CHANNEL_APP_NAME.app"
export npm_config_prefix="$RUNNER_TEMP/npm-global"
npm install --global "create-dmg@${CREATE_DMG_VERSION}" >/dev/null
work="$(mktemp -d "$RUNNER_TEMP/dmg.XXXXXX")"
mkdir -p signer-out
# create-dmg copies the app with the process umask.
umask 022
"$npm_config_prefix/bin/create-dmg" --no-code-sign "$app" "$work"
created="$(find "$work" -maxdepth 1 -name '*.dmg' -print -quit)"
[[ -n "$created" ]] || { echo "create-dmg made no DMG" >&2; exit 1; }
hdiutil convert "$created" -quiet -format ULMO -ov -o "signer-out/$NIGHTLY_DMG_RELEASE"
format="$(hdiutil imageinfo "signer-out/$NIGHTLY_DMG_RELEASE" | awk -F': *' '/^Format:/ {print $2; exit}')"
[[ "$format" == ULMO ]] || { echo "expected an ULMO (LZMA) DMG, got ${format:-unknown}" >&2; exit 1; }
sha="$(shasum -a 256 "signer-out/$NIGHTLY_DMG_RELEASE" | cut -d' ' -f1)"
floor="$(python3 scripts/ci/appcast_minimum_system_version.py floor "$app")"
[[ "$floor" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "no macOS floor for $app" >&2; exit 1; }
{ echo "sha256=$sha"; echo "floor=$floor"; } >> "$GITHUB_OUTPUT"
echo "Unsigned DMG $NIGHTLY_DMG_RELEASE sha256 $sha, macOS floor $floor" >> "$GITHUB_STEP_SUMMARY"
