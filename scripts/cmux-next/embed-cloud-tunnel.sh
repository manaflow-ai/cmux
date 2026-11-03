#!/usr/bin/env bash
# The app target's last Cloud Tunnel step (plans/cmux-next/cloud-tunnel-DESIGN.md).
#
# A Debug build, or a Release build with CMUX_CLOUD_TUNNEL=YES, keeps the
# embedded system extension: it gets the app's identity (stamp), an ad hoc
# signature over the stamped Info.plist (release signing is
# scripts/sign-cmux-bundle.sh), and the build-time bundle check.
#
# Any other Release build removes the extension. A channel ships the tunnel only
# when it has a Developer ID profile for <app id>.tunnel; until then the signed
# app reports "this build does not include the Cloud Tunnel", and the signing
# gates in sign-cmux-bundle.sh still refuse a bundled extension.
#
# Usage: embed-cloud-tunnel.sh APP_PATH
# Environment: CONFIGURATION (Xcode), CMUX_CLOUD_TUNNEL (YES to ship it)
set -euo pipefail

app="${1:?usage: embed-cloud-tunnel.sh APP_PATH}"
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dir="$app/Contents/Library/SystemExtensions"

if [[ "${CONFIGURATION:-Debug}" == "Release" && "${CMUX_CLOUD_TUNNEL:-NO}" != "YES" ]]; then
  [[ -d "$dir" ]] && echo "cloud tunnel: not shipped in this Release build (CMUX_CLOUD_TUNNEL is not YES); removing it"
  rm -rf "$dir"
  exit 0
fi

"$scripts/stamp-cloud-tunnel-identity.sh" "$app"
shopt -s nullglob
for ext in "$dir"/*.systemextension; do
  /usr/bin/codesign --force --sign - "$ext" >/dev/null
done
exec "$scripts/check-cloud-tunnel-bundle.sh" "$app"
