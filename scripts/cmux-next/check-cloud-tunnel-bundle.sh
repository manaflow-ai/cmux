#!/usr/bin/env bash
# Checks the Cloud Tunnel system extension inside a built cmux app, so System
# Settings > Network Extensions shows a proper row: the containing app's name
# and icon as title and icon, "cmux Cloud Tunnel" as subtitle (macOS takes the
# title and icon from the app that activated the extension, the subtitle from
# the extension's CFBundleDisplayName; plans/cmux-next/cloud-tunnel-DESIGN.md).
#
# Usage: check-cloud-tunnel-bundle.sh APP_PATH [--allow-missing]
#   --allow-missing  pass when the app carries no extension (a build signed
#                    without a provisioning profile strips it)
set -euo pipefail

app="${1:?usage: check-cloud-tunnel-bundle.sh APP_PATH [--allow-missing]}"
allow_missing=0
[[ "${2:-}" == "--allow-missing" ]] && allow_missing=1
failures=0
fail() { echo "error: cloud tunnel bundle: $*" >&2; failures=$((failures + 1)); }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

[[ -d "$app" ]] || { echo "error: no app at $app" >&2; exit 1; }
app_plist="$app/Contents/Info.plist"
app_id="$(plist "$app_plist" CFBundleIdentifier)"
dir="$app/Contents/Library/SystemExtensions"
shopt -s nullglob
extensions=("$dir"/*.systemextension)
if ((${#extensions[@]} == 0)); then
  ((allow_missing)) && { echo "cloud tunnel bundle: no extension (allowed)"; exit 0; }
  echo "error: cloud tunnel bundle: $dir holds no .systemextension" >&2
  exit 1
fi
((${#extensions[@]} == 1)) || fail "expected one extension in $dir, found ${#extensions[@]}"
ext="${extensions[0]}"
ext_plist="$ext/Contents/Info.plist"
ext_id="$(plist "$ext_plist" CFBundleIdentifier)"

[[ "$ext_id" == "$app_id.tunnel" ]] || fail "extension id '$ext_id' is not the app id '$app_id' plus .tunnel"
[[ "$(basename "$ext")" == "$ext_id.systemextension" ]] || fail "bundle is named $(basename "$ext"); macOS requires $ext_id.systemextension"
[[ "$(plist "$ext_plist" CFBundlePackageType)" == "SYSX" ]] || fail "CFBundlePackageType is not SYSX"
[[ -n "$(plist "$ext_plist" CFBundleDisplayName)" ]] || fail "no CFBundleDisplayName (the System Settings subtitle)"
[[ -n "$(plist "$ext_plist" NSSystemExtensionUsageDescription)" ]] || fail "no NSSystemExtensionUsageDescription"
[[ -n "$(plist "$ext_plist" "NetworkExtension:NEProviderClasses:com.apple.networkextension.packet-tunnel")" ]] \
  || fail "no packet-tunnel provider class in NetworkExtension:NEProviderClasses"
mach="$(plist "$ext_plist" NetworkExtension:NEMachServiceName)"
[[ "$mach" =~ ^[A-Z0-9]{10}\.(.+)$ && "${BASH_REMATCH[1]}" == "$ext_id" ]] \
  || fail "NEMachServiceName '$mach' is not <team id>.$ext_id"
executable="$(plist "$ext_plist" CFBundleExecutable)"
[[ -n "$executable" && -x "$ext/Contents/MacOS/$executable" ]] || fail "extension executable '$executable' is missing"
for key in CFBundleVersion CFBundleShortVersionString; do
  [[ "$(plist "$ext_plist" "$key")" == "$(plist "$app_plist" "$key")" ]] \
    || fail "extension $key '$(plist "$ext_plist" "$key")' differs from the app's '$(plist "$app_plist" "$key")' (macOS replaces an extension only with a newer version)"
done

# The System Settings title and icon come from the containing app.
[[ -n "$(plist "$app_plist" CFBundleName)" ]] || fail "the app has no CFBundleName (the System Settings title)"
icon="$(plist "$app_plist" CFBundleIconFile)"
[[ -n "$icon" ]] || fail "the app has no CFBundleIconFile (the System Settings icon)"
if [[ -n "$icon" ]]; then
  [[ "$icon" == *.icns ]] || icon="$icon.icns"
  [[ -s "$app/Contents/Resources/$icon" ]] || fail "the app's icon $icon is not in Contents/Resources"
fi

if ((failures)); then
  echo "cloud tunnel bundle: $failures problem(s) in $ext" >&2
  exit 1
fi
echo "cloud tunnel bundle: ok ($ext_id in $(basename "$app"))"
