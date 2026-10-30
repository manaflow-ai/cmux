#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Signs the unsigned dev helper (build-cua-helper-dev.sh) with an Apple
# Development identity from this Mac's keychain, verifies it, and publishes the
# signed zip (publish-cua-pinned-asset.sh, prefix cua-helper-dev) with its pin
# cua-helper-dev.pin.json. Every DEV build then embeds these exact bytes, so
# the helper's code identity (and its macOS grant) stays the same across
# builds until the pin changes. Codesign only: nothing is built here. The
# signing key never leaves this Mac and is never uploaded.
#
#   sign-cua-helper-dev.sh UNSIGNED.zip [--identity NAME] [--dry-run]
#
# A keychain password prompt means a person must unlock the keychain; this
# script never unlocks it.
set -euo pipefail
zip="${1:?usage: sign-cua-helper-dev.sh UNSIGNED.zip [--identity NAME] [--dry-run]}"; shift
identity=""; dry=()
while (( $# )); do
  case "$1" in
    --identity) identity="${2:?}"; shift 2 ;;
    --dry-run) dry=(--dry-run); shift ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
[[ -n "$identity" ]] || { echo "error: no Apple Development identity in the keychain" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ditto -x -k "$zip" "$work"
app="$work/cmux Computer Use (dev).app"
[[ -d "$app" ]] || { echo "error: $zip has no cmux Computer Use (dev).app" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.cmuxterm.cua.dev ]] ||
  { echo "error: unexpected bundle id" >&2; exit 1; }
# Hardened runtime; library validation holds because the dylib carries the same team signature.
codesign --force --options runtime --timestamp=none --sign "$identity" "$app/Contents/Frameworks/libcua_driver_sdk.dylib"
codesign --force --options runtime --timestamp=none --sign "$identity" "$app"
codesign --verify --strict --deep --verbose=2 "$app"
codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => /designated requirement: /p'
signed="$work/out/cmux-computer-use-dev-macos-arm64.zip"
mkdir -p "$work/out"
ditto -c -k --keepParent --sequesterRsrc "$app" "$signed"
tree="$(/usr/libexec/PlistBuddy -c 'Print :CmuxHelperSourceTree' "$app/Contents/Info.plist")"
sdk="$(/usr/libexec/PlistBuddy -c 'Print :CmuxCuaDriverSDKSha256' "$app/Contents/Info.plist")"
team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
"$SCRIPT_DIR/publish-cua-pinned-asset.sh" --file "$signed" --prefix cua-helper-dev \
  --pin "$SCRIPT_DIR/cua-helper-dev.pin.json" --field bundle_id=com.cmuxterm.cua.dev \
  --field helper_source_tree="$tree" --field cua_driver_sdk_sha256="$sdk" \
  --field signing="Apple Development" --field team_id="$team" \
  --field unsigned_sha256="$(shasum -a 256 "$zip" | awk '{print $1}')" ${dry[@]+"${dry[@]}"}
