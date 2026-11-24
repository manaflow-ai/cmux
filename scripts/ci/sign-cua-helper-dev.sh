#!/usr/bin/env bash
# Signs the unsigned dev Computer Use helper that feat-cmux-next's
# build-cua-helper-dev.sh makes, for cmux-next-cua-helper-dev-sign.yml.
#
# This copy lives on main on purpose: the job that runs it holds the Developer
# ID key, so only reviewed main code runs there. The feat-cmux-next build comes
# in as data (a zip); nothing from it is executed, sourced or read as code.
# It follows feat-cmux-next's scripts/cmux-next/sign-cua-helper-dev.sh, and the
# pin it writes has the same fields as cua-helper-dev.pin.json.
#
#   sign-cua-helper-dev.sh UNSIGNED.zip --identity NAME --keychain PATH --out DIR
#
# Writes DIR/cmux-computer-use-dev-macos-arm64.zip and DIR/cua-helper-dev.pin.json.
# The workflow uploads the zip to R2 at the pin's r2_key.
set -euo pipefail
# The entries of DIR (dotfiles too), sorted and space-joined. LC_ALL=C pins
# both ls and sort to byte order: under en_US.UTF-8 they put
# libcua_driver_sdk.dylib before libWebRTC.dylib, which made the exact
# comparison reject a good helper.
# shellcheck disable=SC2012 # bundle file names, one per line; any oddity fails the match
entries() { LC_ALL=C ls -A "$1" | LC_ALL=C sort | tr '\n' ' '; }
# True when DIR holds exactly NAMES, in any order.
holds_only() { local dir="$1"; shift; [[ "$(entries "$dir")" == "$(printf '%s\n' "$@" | LC_ALL=C sort | tr '\n' ' ')" ]]; }
# Sourced (scripts/ci/tests/sign-cua-helper-dev.test.sh): define the helpers only.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
usage="usage: sign-cua-helper-dev.sh UNSIGNED.zip --identity NAME --keychain PATH --out DIR"
zip="${1:?$usage}"; shift
identity=""; keychain=""; out=""
while (( $# )); do
  case "$1" in
    --identity) identity="${2:?}"; shift 2 ;;
    --keychain) keychain="${2:?}"; shift 2 ;;
    --out) out="${2:?}"; shift 2 ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done
[[ -f "$zip" && -n "$identity" && -n "$keychain" && -n "$out" ]] || { echo "$usage" >&2; exit 2; }
asset=cmux-computer-use-dev-macos-arm64.zip
bucket=cmux-cef
team_id=7WLXT3NR37
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ditto -x -k "$zip" "$work"
app="$work/cmux Computer Use (dev).app"
[[ -d "$app" ]] || { echo "error: $zip has no cmux Computer Use (dev).app" >&2; exit 1; }
# Exactly the bundle build-cua-helper-dev.sh makes: the helper executable and
# the Cua Driver SDK dylib, and, since the one permission app (feat-cmux-next
# docs/cmux-remote.md), cmux-remote (the supervisor the daemon spawns from
# this helper) with the libWebRTC.dylib it links. No symlink and no nested
# .framework, so nothing escapes the extracted app and nothing is left unsigned.
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.cmuxterm.cua.dev ]] ||
  { echo "error: unexpected bundle id" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")" == cmux-cua-helper ]] ||
  { echo "error: unexpected executable" >&2; exit 1; }
[[ -z "$(find "$app" -type l -print)" ]] || { echo "error: the helper must not contain symlinks" >&2; exit 1; }
[[ -z "$(find "$app" -type d -name '*.framework' -print)" ]] ||
  { echo "error: the helper must not contain a nested .framework" >&2; exit 1; }
remote="$app/Contents/MacOS/cmux-remote"
macos="$app/Contents/MacOS"
frameworks="$app/Contents/Frameworks"
if [[ -e "$remote" ]]; then
  holds_only "$macos" cmux-cua-helper cmux-remote ||
    { echo "error: Contents/MacOS must hold only cmux-cua-helper and cmux-remote (has: $(entries "$macos"))" >&2; exit 1; }
  holds_only "$frameworks" libcua_driver_sdk.dylib libWebRTC.dylib ||
    { echo "error: Contents/Frameworks must hold only libcua_driver_sdk.dylib and libWebRTC.dylib (has: $(entries "$frameworks"))" >&2; exit 1; }
else
  holds_only "$macos" cmux-cua-helper ||
    { echo "error: Contents/MacOS must hold only cmux-cua-helper (has: $(entries "$macos"))" >&2; exit 1; }
  holds_only "$frameworks" libcua_driver_sdk.dylib ||
    { echo "error: Contents/Frameworks must hold only libcua_driver_sdk.dylib (has: $(entries "$frameworks"))" >&2; exit 1; }
fi
tree="$(/usr/libexec/PlistBuddy -c 'Print :CmuxHelperSourceTree' "$app/Contents/Info.plist")"
sdk="$(/usr/libexec/PlistBuddy -c 'Print :CmuxCuaDriverSDKSha256' "$app/Contents/Info.plist")"
[[ "$tree" =~ ^[0-9a-f]{64}$ && "$sdk" =~ ^[0-9a-f]{64}$ ]] || { echo "error: the helper's provenance keys are not sha256s" >&2; exit 1; }

# Hardened runtime and Apple's time stamp, which Developer ID needs; library
# validation holds because the dylib carries the same team signature.
sign() { codesign --force --options runtime --timestamp --keychain "$keychain" --sign "$identity" "$@"; }
# Nested code before the app that seals it. cmux-remote takes the helper's
# identifier, so macOS names the same permission row (com.cmuxterm.cua.dev)
# whether it attributes the process to the bundle or to the code's own
# signature.
sign "$app/Contents/Frameworks/libcua_driver_sdk.dylib"
if [[ -e "$remote" ]]; then
  sign "$app/Contents/Frameworks/libWebRTC.dylib"
  sign --identifier com.cmuxterm.cua.dev "$remote"
fi
sign "$app"
codesign --verify --strict --deep --verbose=2 "$app"
if [[ -e "$remote" ]]; then
  codesign --verify --strict \
    -R="identifier \"com.cmuxterm.cua.dev\" and anchor apple generic and certificate leaf[subject.OU] = \"$team_id\"" "$remote"
fi
team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$team" == "$team_id" ]] || { echo "error: signed by team $team, not cmux's" >&2; exit 1; }
signing="$(codesign -dvv "$app" 2>&1 | sed -nE 's/^Authority=(Developer ID Application|Apple Development):.*/\1/p' | head -1)"
[[ "$signing" == "Developer ID Application" ]] || { echo "error: the leaf certificate is not Developer ID Application" >&2; exit 1; }
codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => /designated requirement: /p'

mkdir -p "$out"
rm -f "$out/$asset"
ditto -c -k --keepParent --sequesterRsrc "$app" "$out/$asset"
sha="$(shasum -a 256 "$out/$asset" | awk '{print $1}')"
/usr/bin/python3 -I - "$out/cua-helper-dev.pin.json" "$asset" "$sha" "$bucket" "$tree" "$sdk" "$signing" "$team" \
  "$(shasum -a 256 "$zip" | awk '{print $1}')" <<'PY'
import json, sys
path, asset, sha, bucket, tree, sdk, signing, team, unsigned = sys.argv[1:]
with open(path, "w", encoding="utf-8") as f:
    json.dump({
        "asset": asset, "arch": "arm64", "sha256": sha, "r2_bucket": bucket,
        "r2_key": f"cua-helper-dev/{sha}/{asset}", "bundle_id": "com.cmuxterm.cua.dev",
        "helper_source_tree": tree, "cua_driver_sdk_sha256": sdk, "signing": signing,
        "team_id": team, "unsigned_sha256": unsigned,
    }, f, indent=2)
    f.write("\n")
PY
echo "signed $asset sha256 $sha"
