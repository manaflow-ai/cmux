#!/usr/bin/env bash
# install-device.sh: sign an unsigned iphoneos build from `remote-ios.sh device`
# with a local Apple Development identity and install it on a connected iPhone.
#
#   ios-next/scripts/install-device.sh --zip Drawer.zip --profile drawer.mobileprovision \
#     --identity "Apple Development: ..." --device <udid> [--launch] [--env K=V ...]
#
# Signing happens only on this Mac; the build host never sees signing material.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

zip=""; profile=""; identity=""; device=""; launch=0; envs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --zip) zip="$2"; shift 2 ;;
    --profile) profile="$2"; shift 2 ;;
    --identity) identity="$2"; shift 2 ;;
    --device) device="$2"; shift 2 ;;
    --launch) launch=1; shift ;;
    --env) envs+=("$2"); shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -n "$zip" && -n "$profile" && -n "$identity" && -n "$device" ]] || { echo "missing args" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ditto -x -k "$zip" "$work"
app="$(find "$work" -maxdepth 1 -name '*.app' | head -1)"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"

# Entitlements come from the profile (application-identifier, team, Sign in
# with Apple, keychain group, get-task-allow).
security cms -D -i "$profile" > "$work/profile.plist"
plutil -extract Entitlements xml1 -o "$work/ent.plist" "$work/profile.plist"
cp "$profile" "$app/embedded.mobileprovision"

# Inner code first, then the app.
find "$app" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.appex' \) -print0 |
  while IFS= read -r -d '' item; do
    codesign --force --sign "$identity" --timestamp=none --preserve-metadata=identifier "$item" >/dev/null
  done
codesign --force --sign "$identity" --timestamp=none --entitlements "$work/ent.plist" "$app"
codesign --verify --deep --strict "$app"

xcrun devicectl device install app --device "$device" "$app" >/dev/null
echo "installed $bundle_id on $device"

if [[ "$launch" == 1 ]]; then
  json="{}"
  if [[ ${#envs[@]} -gt 0 ]]; then
    json="$(python3 -c 'import json,sys;print(json.dumps(dict(e.split("=",1) for e in sys.argv[1:])))' "${envs[@]}")"
  fi
  xcrun devicectl device process launch --device "$device" --terminate-existing \
    --environment-variables "$json" "$bundle_id" >/dev/null
  echo "launched $bundle_id"
fi
