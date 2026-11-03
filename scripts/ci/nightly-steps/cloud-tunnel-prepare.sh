#!/usr/bin/env bash
# Prepares the opt-in Cloud Tunnel system extension (plans/cmux-next/cloud-tunnel-DESIGN.md)
# for scripts/sign-cmux-bundle.sh, after prepare_variant gave the app its channel identity.
#
# The extension is in the app only when the build ran with CMUX_CLOUD_TUNNEL=YES (a channel with
# a provisioning profile). Then this step:
#   - gives it the channel identity: <app id>.tunnel, the app's versions, a matching bundle name;
#   - checks the channel's tunnel profile (APPLE_<CHANNEL>_TUNNEL_PROVISIONING_PROFILE_BASE64) is a
#     Developer ID profile for that id that grants the packet tunnel system extension;
#   - writes the app entitlements plus the two the tunnel needs, and exports
#     CMUX_CLOUD_TUNNEL_PROFILE, CMUX_CLOUD_TUNNEL_ENTITLEMENTS and CMUX_APP_TUNNEL_ENTITLEMENTS.
# Without the tunnel profile secret it removes the extension: no profile, no tunnel.
#
# Env: CHANNEL_APP_PATH, CHANNEL_BUNDLE_ID, CHANNEL_ENTITLEMENTS, PROFILE_CHANNEL (NIGHTLY, RC or
# RELEASE), TUNNEL_PROVISIONING_PROFILE_BASE64, RUNNER_TEMP, GITHUB_ENV.
set -euo pipefail

app="${CHANNEL_APP_PATH:?}"
dir="$app/Contents/Library/SystemExtensions"
if [[ ! -d "$dir" ]]; then
  echo "cloud tunnel: not in this build"
  exit 0
fi
if [[ -z "${TUNNEL_PROVISIONING_PROFILE_BASE64:-}" || -z "${PROFILE_CHANNEL:-}" ]]; then
  echo "::notice::cloud tunnel: no tunnel provisioning profile for this channel; removing the extension"
  rm -rf "$dir"
  exit 0
fi

# The app's own profile must grant the tunnel too, or signing would stop: no grant, no tunnel.
app_profile_plist="$RUNNER_TEMP/cmux-app-profile.plist"
if [[ ! -f "$app/Contents/embedded.provisionprofile" ]] \
  || ! security cms -D -i "$app/Contents/embedded.provisionprofile" > "$app_profile_plist" 2>/dev/null \
  || ! /usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.networking.networkextension" "$app_profile_plist" 2>/dev/null | grep -q packet-tunnel-provider-systemextension \
  || [[ "$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.system-extension.install" "$app_profile_plist" 2>/dev/null)" != "true" ]]; then
  echo "::warning::cloud tunnel: the $PROFILE_CHANNEL app profile does not grant the packet tunnel and system extension install; removing the extension"
  rm -rf "$dir"
  exit 0
fi

team=7WLXT3NR37
ext_id="${CHANNEL_BUNDLE_ID:?}.tunnel"
channel="$(tr '[:upper:]' '[:lower:]' <<<"$PROFILE_CHANNEL")"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ext_entitlements="$repo/CloudTunnelExtension/cmux-cloud-tunnel.$channel.entitlements"
[[ -f "$ext_entitlements" ]] || { echo "error: no $ext_entitlements" >&2; exit 1; }

"$repo/scripts/cmux-next/stamp-cloud-tunnel-identity.sh" "$app" "$team"

pb() { /usr/libexec/PlistBuddy "$@"; }
want="$team.$ext_id"
have="$(pb -c "Print :com.apple.application-identifier" "$ext_entitlements")"
[[ "$have" == "$want" ]] || { echo "error: $(basename "$ext_entitlements") is for $have, not $want" >&2; exit 1; }

profile="$RUNNER_TEMP/cmux-cloud-tunnel.provisionprofile"
decoded="$RUNNER_TEMP/cmux-cloud-tunnel.profile.plist"
base64 --decode <<<"$TUNNEL_PROVISIONING_PROFILE_BASE64" > "$profile"
security cms -D -i "$profile" > "$decoded"
have="$(pb -c "Print :Entitlements:com.apple.application-identifier" "$decoded")"
[[ "$have" == "$want" ]] || { echo "error: the $PROFILE_CHANNEL tunnel profile is for $have, not $want" >&2; exit 1; }
pb -c "Print :Entitlements:com.apple.developer.networking.networkextension" "$decoded" | grep -q packet-tunnel-provider-systemextension \
  || { echo "error: the $PROFILE_CHANNEL tunnel profile does not grant packet-tunnel-provider-systemextension" >&2; exit 1; }
[[ "$(pb -c "Print :ProvisionsAllDevices" "$decoded" 2>/dev/null)" == "true" ]] \
  || { echo "error: the $PROFILE_CHANNEL tunnel profile is not a Developer ID profile" >&2; exit 1; }

app_entitlements="$RUNNER_TEMP/cmux-app-cloud-tunnel.entitlements"
cp "${CHANNEL_ENTITLEMENTS:?}" "$app_entitlements"
pb -c "Delete :com.apple.developer.networking.networkextension" "$app_entitlements" >/dev/null 2>&1 || true
pb -c "Add :com.apple.developer.networking.networkextension array" \
   -c "Add :com.apple.developer.networking.networkextension:0 string packet-tunnel-provider-systemextension" \
   "$app_entitlements"
pb -c "Delete :com.apple.developer.system-extension.install" "$app_entitlements" >/dev/null 2>&1 || true
pb -c "Add :com.apple.developer.system-extension.install bool true" "$app_entitlements"

{
  echo "CMUX_CLOUD_TUNNEL_PROFILE=$profile"
  echo "CMUX_CLOUD_TUNNEL_ENTITLEMENTS=$ext_entitlements"
  echo "CMUX_APP_TUNNEL_ENTITLEMENTS=$app_entitlements"
} >> "${GITHUB_ENV:?}"
echo "cloud tunnel: $ext_id ready to sign with the $PROFILE_CHANNEL tunnel profile"
