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
# Exactly the bundle build-cua-helper-dev.sh makes: one executable, one dylib.
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.cmuxterm.cua.dev ]] ||
  { echo "error: unexpected bundle id" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")" == cmux-cua-helper ]] ||
  { echo "error: unexpected executable" >&2; exit 1; }
[[ "$(ls "$app/Contents/Frameworks")" == libcua_driver_sdk.dylib ]] ||
  { echo "error: Contents/Frameworks must hold only libcua_driver_sdk.dylib" >&2; exit 1; }
tree="$(/usr/libexec/PlistBuddy -c 'Print :CmuxHelperSourceTree' "$app/Contents/Info.plist")"
sdk="$(/usr/libexec/PlistBuddy -c 'Print :CmuxCuaDriverSDKSha256' "$app/Contents/Info.plist")"
[[ "$tree" =~ ^[0-9a-f]{64}$ && "$sdk" =~ ^[0-9a-f]{64}$ ]] || { echo "error: the helper's provenance keys are not sha256s" >&2; exit 1; }

# Hardened runtime and Apple's time stamp, which Developer ID needs; library
# validation holds because the dylib carries the same team signature.
sign() { codesign --force --options runtime --timestamp --keychain "$keychain" --sign "$identity" "$@"; }
sign "$app/Contents/Frameworks/libcua_driver_sdk.dylib"
sign "$app"
codesign --verify --strict --deep --verbose=2 "$app"
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
