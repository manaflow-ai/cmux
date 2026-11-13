#!/usr/bin/env bash
# Signs the unsigned cmux Remote (dev) bundle produced by
# feat-cmux-next's build-cmux-remote-dev.sh. This copy is intentionally on
# main: it is the only code that runs while the Developer ID keychain exists.
# The feat-cmux-next build is input data and is never sourced or executed here.
set -euo pipefail

usage="usage: sign-cmux-remote-dev.sh UNSIGNED.zip --identity NAME --keychain PATH --out DIR"
zip="${1:?$usage}"
shift
identity=""
keychain=""
out=""
while (( $# )); do
  case "$1" in
    --identity) identity="${2:?}"; shift 2 ;;
    --keychain) keychain="${2:?}"; shift 2 ;;
    --out) out="${2:?}"; shift 2 ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done
[[ -f "$zip" && -n "$identity" && -n "$keychain" && -n "$out" ]] || { echo "$usage" >&2; exit 2; }

asset="cmux-remote-dev-macos-arm64.zip"
bucket="cmux-cef"
team_id="7WLXT3NR37"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ditto -x -k "$zip" "$work"
app="$work/cmux Remote (dev).app"
[[ ! -L "$app" && -d "$app" ]] || { echo "error: $zip has no regular cmux Remote (dev).app" >&2; exit 1; }

# Do not let an archive symlink escape the extracted app during signing or
# provenance inspection. Keep the marker outside the app so it cannot affect
# the bundle that is later re-zipped.
symlinks_marker="$work/symlinks.marker"
find "$app" -type l -print > "$symlinks_marker"
[[ ! -s "$symlinks_marker" ]] || { echo "error: cmux Remote must not contain symlinks" >&2; exit 1; }

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist"; }
[[ "$(plist CFBundleIdentifier)" == com.cmuxterm.remote.dev ]] ||
  { echo "error: unexpected cmux Remote bundle id" >&2; exit 1; }
[[ "$(plist CFBundleExecutable)" == cmux-remote ]] ||
  { echo "error: unexpected cmux Remote executable" >&2; exit 1; }
[[ -x "$app/Contents/MacOS/cmux-remote" ]] ||
  { echo "error: cmux Remote executable is missing or not executable" >&2; exit 1; }
tree="$(plist CmuxRemoteSourceTree)"
sdk="$(plist CmuxCuaDriverSDKSha256)"
[[ "$tree" =~ ^[0-9a-f]{64}$ && "$sdk" =~ ^[0-9a-f]{64}$ ]] ||
  { echo "error: Remote provenance keys are not sha256s" >&2; exit 1; }

framework_dir="$app/Contents/Frameworks"
[[ -d "$framework_dir" ]] || { echo "error: Remote has no Frameworks directory" >&2; exit 1; }
framework_count=0
for dylib in "$framework_dir"/*.dylib; do
  [[ -f "$dylib" ]] || continue
  case "${dylib##*/}" in
    libWebRTC.dylib|libcua_driver_sdk.dylib) ;;
    *) echo "error: unexpected Remote framework ${dylib##*/}" >&2; exit 1 ;;
  esac
  framework_count=$((framework_count + 1))
done
[[ "$framework_count" == 2 && -f "$framework_dir/libWebRTC.dylib" && -f "$framework_dir/libcua_driver_sdk.dylib" ]] ||
  { echo "error: Remote Frameworks must contain exactly libWebRTC.dylib and libcua_driver_sdk.dylib" >&2; exit 1; }
frameworks_marker="$work/frameworks.marker"
find "$app" -type d -name '*.framework' -print > "$frameworks_marker"
if [[ -s "$frameworks_marker" ]]; then
  echo "error: cmux Remote must not contain nested frameworks" >&2
  exit 1
fi

sign() {
  codesign --force --options runtime --timestamp --keychain "$keychain" --sign "$identity" "$@"
}
sign "$framework_dir/libcua_driver_sdk.dylib"
sign "$framework_dir/libWebRTC.dylib"
sign "$app"
codesign --verify --strict --deep --verbose=2 "$app"
team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$team" == "$team_id" ]] || { echo "error: signed by team $team, not cmux's" >&2; exit 1; }
codesign --verify --strict --deep \
  -R="identifier \"com.cmuxterm.remote.dev\" and anchor apple generic and certificate leaf[subject.OU] = \"$team_id\"" \
  "$app"
signing="$(codesign -dvv "$app" 2>&1 | sed -nE 's/^Authority=(Developer ID Application):.*/\1/p' | head -1)"
[[ "$signing" == "Developer ID Application" ]] ||
  { echo "error: the leaf certificate is not Developer ID Application" >&2; exit 1; }

mkdir -p "$out"
rm -f "$out/$asset"
ditto -c -k --keepParent --sequesterRsrc "$app" "$out/$asset"
sha="$(shasum -a 256 "$out/$asset" | awk '{print $1}')"
/usr/bin/python3 -I - "$out/cmux-remote-dev.pin.json" "$sha" "$tree" "$sdk" "$signing" "$team" \
  "$(shasum -a 256 "$zip" | awk '{print $1}')" <<'PY'
import json, sys
path, sha, tree, sdk, signing, team, unsigned = sys.argv[1:]
with open(path, "w", encoding="utf-8") as f:
    json.dump({
        "asset": "cmux-remote-dev-macos-arm64.zip",
        "arch": "arm64",
        "sha256": sha,
        "r2_bucket": "cmux-cef",
        "r2_key": f"cua-helper-dev/{sha}/cmux-remote-dev-macos-arm64.zip",
        "bundle_id": "com.cmuxterm.remote.dev",
        "remote_source_tree": tree,
        "cua_driver_sdk_sha256": sdk,
        "signing": signing,
        "team_id": team,
        "unsigned_sha256": unsigned,
    }, f, indent=2)
    f.write("\n")
PY
echo "signed $asset sha256 $sha"
