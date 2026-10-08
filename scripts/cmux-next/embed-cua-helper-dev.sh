#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Xcode "Embed Computer Use helper (dev)" phase of the cmux-next target. DEV
# builds only: copies the pinned, Apple Development signed
# "cmux Computer Use (dev).app" (cua-helper-dev.pin.json) to
#   Contents/Library/cmux Computer Use (dev).app
# where ComputerUseHelperV2 starts it for computerUse.driver = "upstream".
# The bytes are never re-signed here (the helper's code identity, and so its
# macOS grant, must stay the same across builds); Xcode signs the outer app
# without --deep. Release embeds nothing. An unavailable helper (no R2 read
# credentials) warns and embeds nothing unless CMUX_NEXT_REQUIRE_CUA_HELPER=1;
# a sha256 mismatch fails the build. CMUX_NEXT_SKIP_CUA_HELPER=1 embeds nothing.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
name="cmux Computer Use (dev).app"
dest="$app/Contents/Library/$name"
stamp="${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}/embed-cua-helper-dev.stamp"
skip() {
  echo "note: not embedding the Computer Use helper (dev): $1"
  rm -rf "$dest" "$stamp"
  rmdir "$app/Contents/Library" 2>/dev/null || true
  exit 0
}
[[ "${CONFIGURATION:-}" == "Release" ]] && skip "Release configuration (DEV builds only)"
[[ "${CMUX_NEXT_SKIP_CUA_HELPER:-0}" == "1" ]] && skip "CMUX_NEXT_SKIP_CUA_HELPER=1"
[[ " ${ARCHS:-arm64} " == *" arm64 "* ]] || skip "ARCHS=${ARCHS:-} has no arm64"
pin="${CMUX_NEXT_CUA_HELPER_PIN:-$SCRIPT_DIR/cua-helper-dev.pin.json}"
[[ -f "$pin" ]] || skip "no pin file $pin"
args=(--optional)
[[ "${CMUX_NEXT_REQUIRE_CUA_HELPER:-0}" == "1" ]] && args=()
zip="$("$SCRIPT_DIR/ensure-cua-pinned-asset.sh" "$pin" ${args[@]+"${args[@]}"})"
[[ -n "$zip" ]] || skip "the pinned helper is unavailable"
want="$(shasum -a 256 "$zip" | awk '{print $1}')"
if [[ -f "$stamp" && "$(cat "$stamp")" == "$want" ]] && codesign --verify --strict "$dest" 2>/dev/null; then
  echo "note: Computer Use helper (dev) already embedded ($want)"
  exit 0
fi
rm -rf "$dest"
mkdir -p "$app/Contents/Library"
ditto -x -k "$zip" "$app/Contents/Library"
[[ -d "$dest" ]] || { echo "error: $zip has no $name" >&2; exit 1; }
codesign --verify --strict --deep "$dest" || { echo "error: the embedded helper's signature does not verify" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dest/Contents/Info.plist")" == com.cmuxterm.cua.dev ]] ||
  { echo "error: the embedded helper is not com.cmuxterm.cua.dev" >&2; exit 1; }
echo "$want" > "$stamp"
echo "note: embedded the Computer Use helper (dev) sha256 $want"
