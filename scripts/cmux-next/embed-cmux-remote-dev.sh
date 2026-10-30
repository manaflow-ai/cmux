#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Embeds the pinned, Apple Development signed "cmux Remote (dev).app"
# (cmux-remote-dev.pin.json; docs/cmux-remote.md) at
#   Contents/Library/cmux Remote (dev).app
# of a DEV build, where its cmux-tui daemon finds it, copies it outside the app
# and starts it. Run from the "Embed Computer Use helper (dev)" phase
# (embed-cua-helper-dev.sh). The bytes are never re-signed (cmux Remote's code
# identity, and so its macOS grants, must stay the same across builds).
# Release embeds nothing here. An unavailable pin warns and embeds nothing
# unless CMUX_NEXT_REQUIRE_CMUX_REMOTE=1; a sha256 mismatch fails the build.
# CMUX_NEXT_SKIP_CMUX_REMOTE=1 embeds nothing.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
name="cmux Remote (dev).app"
dest="$app/Contents/Library/$name"
stamp="${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}/embed-cmux-remote-dev.stamp"
skip() {
  echo "note: not embedding cmux Remote (dev): $1"
  rm -rf "$dest"
  rm -f "$stamp"
  exit 0
}
[[ "${CONFIGURATION:-}" == "Release" ]] && skip "Release configuration (DEV builds only)"
[[ "${CMUX_NEXT_SKIP_CMUX_REMOTE:-0}" == "1" ]] && skip "CMUX_NEXT_SKIP_CMUX_REMOTE=1"
[[ " ${ARCHS:-arm64} " == *" arm64 "* ]] || skip "ARCHS=${ARCHS:-} has no arm64"
pin="${CMUX_NEXT_CMUX_REMOTE_PIN:-$SCRIPT_DIR/cmux-remote-dev.pin.json}"
[[ -f "$pin" ]] || skip "no pin file $pin"
args=(--optional)
[[ "${CMUX_NEXT_REQUIRE_CMUX_REMOTE:-0}" == "1" ]] && args=()
zip="$("$SCRIPT_DIR/ensure-cua-pinned-asset.sh" "$pin" ${args[@]+"${args[@]}"})"
[[ -n "$zip" ]] || skip "the pinned cmux Remote is unavailable"
want="$(shasum -a 256 "$zip" | awk '{print $1}')"
if [[ -f "$stamp" && "$(cat "$stamp")" == "$want" ]] && codesign --verify --strict "$dest" 2>/dev/null; then
  echo "note: cmux Remote (dev) already embedded ($want)"
  exit 0
fi
rm -rf "$dest"
mkdir -p "$app/Contents/Library"
ditto -x -k "$zip" "$app/Contents/Library"
[[ -d "$dest" ]] || { echo "error: $zip has no $name" >&2; exit 1; }
codesign --verify --strict --deep "$dest" || { echo "error: the embedded cmux Remote's signature does not verify" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dest/Contents/Info.plist")" == com.cmuxterm.remote.dev ]] ||
  { echo "error: the embedded cmux Remote is not com.cmuxterm.remote.dev" >&2; exit 1; }
python3 -I "$SCRIPT_DIR/../ci/macho_minos.py" scan "$dest" --floor "${MACOSX_DEPLOYMENT_TARGET:-14.0}" ||
  { rm -rf "$dest"; echo "error: the pinned cmux Remote cannot load on macOS ${MACOSX_DEPLOYMENT_TARGET:-14.0}" >&2; exit 1; }
mkdir -p "$(dirname "$stamp")"
echo "$want" > "$stamp"
echo "note: embedded cmux Remote (dev) sha256 $want"
