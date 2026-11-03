#!/usr/bin/env bash
# Makes the Cloud Tunnel system extension follow its app's identity after the
# app's Info.plist was rewritten (nightly/RC channel ids, versions): the
# extension id becomes <app id>.tunnel, its Mach service <team>.<that id>, its
# versions the app's, and the bundle is renamed <id>.systemextension (macOS
# refuses any other name). Idempotent; no extension, nothing to do.
#
# Usage: stamp-cloud-tunnel-identity.sh APP_PATH [TEAM_ID]
set -euo pipefail

app="${1:?usage: stamp-cloud-tunnel-identity.sh APP_PATH [TEAM_ID]}"
team="${2:-7WLXT3NR37}"
dir="$app/Contents/Library/SystemExtensions"
shopt -s nullglob
extensions=("$dir"/*.systemextension)
((${#extensions[@]} > 0)) || { echo "cloud tunnel identity: no extension in $(basename "$app")"; exit 0; }
((${#extensions[@]} == 1)) || { echo "error: more than one system extension in $dir" >&2; exit 1; }

pb() { /usr/libexec/PlistBuddy "$@"; }
app_plist="$app/Contents/Info.plist"
app_id="$(pb -c "Print :CFBundleIdentifier" "$app_plist")"
ext="${extensions[0]}"
ext_plist="$ext/Contents/Info.plist"
ext_id="$app_id.tunnel"

pb -c "Set :CFBundleIdentifier $ext_id" "$ext_plist"
pb -c "Set :NetworkExtension:NEMachServiceName $team.$ext_id" "$ext_plist"
for key in CFBundleVersion CFBundleShortVersionString; do
  pb -c "Set :$key $(pb -c "Print :$key" "$app_plist")" "$ext_plist"
done
target="$dir/$ext_id.systemextension"
[[ "$ext" == "$target" ]] || { rm -rf "$target"; mv "$ext" "$target"; }
echo "cloud tunnel identity: $ext_id ($team)"
