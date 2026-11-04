#!/usr/bin/env bash
# The app target's Cloud Tunnel step (plans/cmux-next/cloud-tunnel-DESIGN.md).
#
# This step is the only place the system extension enters the app: there is no
# Copy Files phase for it. Xcode validates every bundle a Copy Files phase embeds
# (ValidateEmbeddedBinary) after the script phases run, so an unconditional
# embed that a Release build then removed failed that validation.
#
# A Debug build, or a Release build with CMUX_CLOUD_TUNNEL=YES, embeds the built
# extension ($BUILT_PRODUCTS_DIR/cmux-cloud-tunnel.systemextension), gives it the
# app's identity (stamp), an ad hoc signature over the stamped Info.plist (release
# signing is scripts/sign-cmux-bundle.sh), and runs the build-time bundle check.
#
# Any other Release build never embeds it. A channel ships the tunnel only when it
# has a Developer ID profile for <app id>.tunnel; until then the signed app reports
# "this build does not include the Cloud Tunnel", and the signing gates in
# sign-cmux-bundle.sh still refuse a bundled extension.
#
# Usage: embed-cloud-tunnel.sh APP_PATH
# Environment: CONFIGURATION, BUILT_PRODUCTS_DIR (Xcode), CMUX_CLOUD_TUNNEL (YES to ship it)
set -euo pipefail

app="${1:?usage: embed-cloud-tunnel.sh APP_PATH}"
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dir="$app/Contents/Library/SystemExtensions"

# The previous build's copy, if any: an incremental build keeps the app bundle.
rm -rf "$dir"
if [[ "${CONFIGURATION:-Debug}" == "Release" && "${CMUX_CLOUD_TUNNEL:-NO}" != "YES" ]]; then
  echo "cloud tunnel: not shipped in this Release build (CMUX_CLOUD_TUNNEL is not YES); not embedded"
  exit 0
fi

built="${BUILT_PRODUCTS_DIR:?embed-cloud-tunnel.sh runs as an Xcode build phase}/cmux-cloud-tunnel.systemextension"
[[ -d "$built" ]] || { echo "error: cloud tunnel: no built extension at $built" >&2; exit 1; }
mkdir -p "$dir"
/usr/bin/ditto "$built" "$dir/$(basename "$built")"
"$scripts/stamp-cloud-tunnel-identity.sh" "$app"
shopt -s nullglob
for ext in "$dir"/*.systemextension; do
  /usr/bin/codesign --force --sign - "$ext" >/dev/null
done
exec "$scripts/check-cloud-tunnel-bundle.sh" "$app"
