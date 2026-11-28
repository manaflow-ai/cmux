#!/usr/bin/env bash
# nightly.yml publish-nightly: "Assemble legacy nightly names". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
cd nightly-out
ls -l
if [ "$NIGHTLY_TRACK" = nightly-next ]; then
  # arm64 only (decide): no Intel or universal names to assemble.
  [ -f "${CHANNEL_DMG_PREFIX}-arm64.dmg" ] || { echo "missing ${CHANNEL_DMG_PREFIX}-arm64.dmg" >&2; exit 1; }
  [ -f appcast-arm64.xml ] || { echo "missing appcast-arm64.xml" >&2; exit 1; }
  exit 0
fi
for variant in arm64 x86_64; do
  [ -f "${CHANNEL_DMG_PREFIX}-${variant}.dmg" ] || { echo "missing ${CHANNEL_DMG_PREFIX}-${variant}.dmg" >&2; exit 1; }
  [ -f "appcast-${variant}.xml" ] || { echo "missing appcast-${variant}.xml" >&2; exit 1; }
done
# `cmux-nightly-macos.dmg` and `appcast.xml` are the download and feed
# every pre-existing link and install uses. They stay universal: the
# universal variant generates appcast.xml itself, and installs move to
# their architecture's feed on the next update check.
[ "$NIGHTLY_LEGACY_VARIANT" = "universal" ] || { echo "unexpected legacy variant: $NIGHTLY_LEGACY_VARIANT" >&2; exit 1; }
[ -f "${CHANNEL_DMG_PREFIX}-universal.dmg" ] || { echo "universal variant DMG missing" >&2; exit 1; }
[ -f appcast.xml ] || { echo "universal variant appcast.xml missing" >&2; exit 1; }
cp "${CHANNEL_DMG_PREFIX}-universal.dmg" "${CHANNEL_DMG_PREFIX}.dmg"
# Compatibility feed for nightlies older than the unified appcast.
cp appcast.xml appcast-universal.xml
ls -l
