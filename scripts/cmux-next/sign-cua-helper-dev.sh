#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Signs the unsigned dev helper (build-cua-helper-dev.sh), verifies it, and
# publishes the signed zip (publish-cua-pinned-asset.sh, prefix cua-helper-dev)
# with its pin cua-helper-dev.pin.json. Every DEV build then embeds these exact
# bytes, so the helper's code identity (and its macOS grant) stays the same
# across builds until the pin changes. Codesign only: nothing is built here. The
# signing key never leaves the keychain and is never uploaded.
#
#   sign-cua-helper-dev.sh UNSIGNED.zip [--identity NAME] [--keychain PATH]
#       [--timestamp] [--out DIR] [--dry-run]
#
# --identity defaults to the first Apple Development identity in the keychain.
# --keychain signs only from that keychain (CI imports the Developer ID
# certificate into a temporary one, scripts/ci/signing-keychain.sh).
# --timestamp asks Apple's time stamp server, which Developer ID needs; without
# it the signature carries none. --out keeps a copy of the signed zip there.
# The pin's "signing" field records the certificate kind (Apple Development or
# Developer ID Application) from the signature itself.
#
# A keychain password prompt means a person must unlock the keychain; this
# script never unlocks it.
set -euo pipefail
usage="usage: sign-cua-helper-dev.sh UNSIGNED.zip [--identity NAME] [--keychain PATH] [--timestamp] [--out DIR] [--dry-run]"
zip="${1:?$usage}"; shift
identity=""; keychain=(); timestamp=--timestamp=none; out=""; dry=()
while (( $# )); do
  case "$1" in
    --identity) identity="${2:?}"; shift 2 ;;
    --keychain) keychain=(--keychain "${2:?}"); shift 2 ;;
    --timestamp) timestamp=--timestamp; shift ;;
    --out) out="${2:?}"; shift 2 ;;
    --dry-run) dry=(--dry-run); shift ;;
    *) echo "unknown argument $1" >&2; echo "$usage" >&2; exit 2 ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning ${keychain[1]+"${keychain[1]}"} | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
[[ -n "$identity" ]] || { echo "error: no Apple Development identity in the keychain (pass --identity)" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ditto -x -k "$zip" "$work"
app="$work/cmux Computer Use (dev).app"
[[ -d "$app" ]] || { echo "error: $zip has no cmux Computer Use (dev).app" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.cmuxterm.cua.dev ]] ||
  { echo "error: unexpected bundle id" >&2; exit 1; }
# Hardened runtime; library validation holds because the dylib carries the same team signature.
sign() { codesign --force --options runtime "$timestamp" ${keychain[@]+"${keychain[@]}"} --sign "$identity" "$@"; }
sign "$app/Contents/Frameworks/libcua_driver_sdk.dylib"
sign "$app"
codesign --verify --strict --deep --verbose=2 "$app"
team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$team" == 7WLXT3NR37 ]] || { echo "error: signed by team $team, not cmux's" >&2; exit 1; }
# The leaf certificate's kind, from the signature (Authority= lists the chain, leaf first).
signing="$(codesign -dvv "$app" 2>&1 | sed -nE 's/^Authority=(Developer ID Application|Apple Development):.*/\1/p' | head -1)"
[[ -n "$signing" ]] || { echo "error: the leaf certificate is neither Developer ID Application nor Apple Development" >&2; exit 1; }
codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => /designated requirement: /p'
signed="$work/out/cmux-computer-use-dev-macos-arm64.zip"
mkdir -p "$work/out"
ditto -c -k --keepParent --sequesterRsrc "$app" "$signed"
tree="$(/usr/libexec/PlistBuddy -c 'Print :CmuxHelperSourceTree' "$app/Contents/Info.plist")"
sdk="$(/usr/libexec/PlistBuddy -c 'Print :CmuxCuaDriverSDKSha256' "$app/Contents/Info.plist")"
if [[ -n "$out" ]]; then mkdir -p "$out" && cp "$signed" "$out/"; fi
"$SCRIPT_DIR/publish-cua-pinned-asset.sh" --file "$signed" --prefix cua-helper-dev \
  --pin "$SCRIPT_DIR/cua-helper-dev.pin.json" --field bundle_id=com.cmuxterm.cua.dev \
  --field helper_source_tree="$tree" --field cua_driver_sdk_sha256="$sdk" \
  --field signing="$signing" --field team_id="$team" \
  --field unsigned_sha256="$(shasum -a 256 "$zip" | awk '{print $1}')" ${dry[@]+"${dry[@]}"}
