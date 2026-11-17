#!/usr/bin/env bash
# Removes the Computer Use helper's pinned Cua Driver SDK
# (Contents/Library/cmux Computer Use.app/Contents/Frameworks/libcua_driver_sdk.dylib,
# bundle-cmux-remote.sh) from an app bundle when the dylib has no slice for <arch>. The pinned SDK
# (cua-driver-sdk.pin.json) is arm64 only, so a thin x86_64 variant cut from the universal build
# would otherwise fail scripts/thin-app-bundle.sh, and could never load it anyway: the Computer
# Use worker of cmux-remote reports the driver unavailable when the dylib is absent. cmux-remote,
# libWebRTC.dylib and the rest of the helper keep their x86_64 slices.
#
# Usage: drop-cua-sdk-without-arch.sh <app> <arm64|x86_64>
# Run before thinning and signing.
set -euo pipefail
app="${1:?usage: drop-cua-sdk-without-arch.sh <app> <arch>}"
arch="${2:?usage: drop-cua-sdk-without-arch.sh <app> <arch>}"
lipo_tool="${CMUX_LIPO_TOOL:-lipo}"
sdk="$app/Contents/Library/cmux Computer Use.app/Contents/Frameworks/libcua_driver_sdk.dylib"
[[ -f "$sdk" ]] || { echo "no Cua Driver SDK in the Computer Use helper"; exit 0; }
if "$lipo_tool" "$sdk" -verify_arch "$arch" 2>/dev/null; then
  echo "the Cua Driver SDK has an $arch slice; keeping it"
  exit 0
fi
echo "::warning title=No Cua Driver SDK for $arch::the pinned SDK has no $arch slice ($("$lipo_tool" -archs "$sdk" 2>/dev/null || echo unknown)); the $arch app's Computer Use worker reports the driver unavailable"
rm -f "$sdk"
