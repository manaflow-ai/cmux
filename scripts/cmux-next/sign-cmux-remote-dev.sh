#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Signs the unsigned "cmux Remote (dev).app" (build-cmux-remote-dev.sh) with an
# Apple Development identity from this Mac's keychain (hardened runtime; the
# dylib and libWebRTC.dylib get the same team signature, so library
# validation holds), verifies it against the designated requirement the
# cmux-tui daemon checks (identifier com.cmuxterm.remote.dev, cmux's team), and
# writes the signed zip and its pin cmux-remote-dev.pin.json. Every DEV build
# embeds these exact bytes, so cmux Remote's code identity, and the person's
# Accessibility and Screen Recording grants, stay the same until the pin
# changes. Codesign only; nothing is built here; the key never leaves this Mac.
#
#   sign-cmux-remote-dev.sh UNSIGNED.zip [--identity NAME] [--keychain PATH] [--timestamp] [--out DIR]
#
# --identity, --keychain and --timestamp work as in sign-cua-helper-dev.sh: CI
# signs with the Developer ID certificate from a temporary keychain and Apple's
# time stamp; the pin's "signing" field records the certificate kind.
#
# Then publish the zip where builds read it: `cmux-ci artifact-put` (the
# controller store; ensure-cua-pinned-asset.sh reads it by sha256) and, with
# the R2 write credentials, publish-cua-pinned-asset.sh.
set -euo pipefail
zip="${1:?usage: sign-cmux-remote-dev.sh UNSIGNED.zip [--identity NAME] [--keychain PATH] [--timestamp] [--out DIR]}"; shift
identity=""; keychain=(); timestamp=--timestamp=none; out="$PWD"
while (( $# )); do
  case "$1" in
    --identity) identity="${2:?}"; shift 2 ;;
    --keychain) keychain=(--keychain "${2:?}"); shift 2 ;;
    --timestamp) timestamp=--timestamp; shift ;;
    --out) out="${2:?}"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
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
app="$work/cmux Remote (dev).app"
[[ -d "$app" ]] || { echo "error: $zip has no cmux Remote (dev).app" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.cmuxterm.remote.dev ]] ||
  { echo "error: unexpected bundle id" >&2; exit 1; }
sign() { codesign --force --options runtime "$timestamp" ${keychain[@]+"${keychain[@]}"} --sign "$identity" "$@"; }
sign "$app/Contents/Frameworks/libcua_driver_sdk.dylib"
sign "$app/Contents/Frameworks/libWebRTC.dylib"
sign "$app"
team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
codesign --verify --strict --deep -R="identifier \"com.cmuxterm.remote.dev\" and anchor apple generic and certificate leaf[subject.OU] = \"$team\"" "$app"
[[ "$team" == 7WLXT3NR37 ]] || { echo "error: signed by team $team, not cmux's" >&2; exit 1; }
signing="$(codesign -dvv "$app" 2>&1 | sed -nE 's/^Authority=(Developer ID Application|Apple Development):.*/\1/p' | head -1)"
[[ -n "$signing" ]] || { echo "error: the leaf certificate is neither Developer ID Application nor Apple Development" >&2; exit 1; }
mkdir -p "$out"
signed="$out/cmux-remote-dev-macos-arm64.zip"
rm -f "$signed"
ditto -c -k --keepParent --sequesterRsrc "$app" "$signed"
sha="$(shasum -a 256 "$signed" | awk '{print $1}')"
tree="$(/usr/libexec/PlistBuddy -c 'Print :CmuxRemoteSourceTree' "$app/Contents/Info.plist")"
/usr/bin/python3 -I - "$SCRIPT_DIR/cmux-remote-dev.pin.json" "$sha" "$tree" "$team" "$signing" "$(shasum -a 256 "$zip" | awk '{print $1}')" <<'PY'
import json, sys
path, sha, tree, team, signing, unsigned = sys.argv[1:]
json.dump({
    "asset": "cmux-remote-dev-macos-arm64.zip",
    "arch": "arm64",
    "sha256": sha,
    "r2_bucket": "cmux-cef",
    "r2_key": f"cua-helper-dev/{sha}/cmux-remote-dev-macos-arm64.zip",
    "bundle_id": "com.cmuxterm.remote.dev",
    "remote_source_tree": tree,
    "signing": signing,
    "team_id": team,
    "unsigned_sha256": unsigned,
}, open(path, "w"), indent=2)
open(path, "a").write("\n")
PY
echo "$signed"
echo "sha256 $sha"
