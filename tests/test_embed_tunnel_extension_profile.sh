#!/usr/bin/env bash
# Behavior of scripts/ci/embed-tunnel-extension-profile.sh: no profile is a
# no-op notice, a matching profile lands in the extension bundle, and a profile
# for the wrong App ID or without the capability is rejected.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/ci/embed-tunnel-extension-profile.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

APP="$TMP_DIR/cmux.app"
SYSEXT="$APP/Contents/Library/SystemExtensions/cmuxTunnel.systemextension"
mkdir -p "$SYSEXT/Contents/MacOS"

profile_plist() {
  local app_id="$1" capability="$2"
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Entitlements</key>
  <dict>
    <key>com.apple.application-identifier</key>
    <string>${app_id}</string>
    <key>com.apple.developer.networking.networkextension</key>
    <array>
      <string>${capability}</string>
    </array>
  </dict>
  <key>ProvisionsAllDevices</key>
  <true/>
</dict>
</plist>
PLIST
}

# 1. Empty secret: notice, no file, exit 0.
out="$("$SCRIPT" "$APP" "7WLXT3NR37.com.cmuxterm.app.tunnel" "")"
[[ "$out" == *"::notice::"* ]] || { echo "FAIL: expected a notice for the empty profile" >&2; exit 1; }
[[ ! -e "$SYSEXT/Contents/embedded.provisionprofile" ]] || { echo "FAIL: no profile should be embedded" >&2; exit 1; }

# 2. Matching profile lands in the extension.
good="$(profile_plist "7WLXT3NR37.com.cmuxterm.app.tunnel" "packet-tunnel-provider-systemextension" | base64)"
"$SCRIPT" "$APP" "7WLXT3NR37.com.cmuxterm.app.tunnel" "$good" >/dev/null
[[ -s "$SYSEXT/Contents/embedded.provisionprofile" ]] || { echo "FAIL: profile was not embedded" >&2; exit 1; }
rm "$SYSEXT/Contents/embedded.provisionprofile"

# 3. Wrong App ID is rejected.
wrong_id="$(profile_plist "7WLXT3NR37.com.cmuxterm.app" "packet-tunnel-provider-systemextension" | base64)"
if "$SCRIPT" "$APP" "7WLXT3NR37.com.cmuxterm.app.tunnel" "$wrong_id" >/dev/null 2>&1; then
  echo "FAIL: accepted a profile for the wrong App ID" >&2; exit 1
fi

# 4. App-extension capability (not the system-extension one) is rejected.
wrong_cap="$(profile_plist "7WLXT3NR37.com.cmuxterm.app.tunnel" "packet-tunnel-provider" | base64)"
if "$SCRIPT" "$APP" "7WLXT3NR37.com.cmuxterm.app.tunnel" "$wrong_cap" >/dev/null 2>&1; then
  echo "FAIL: accepted a profile without the system-extension capability" >&2; exit 1
fi
[[ ! -e "$SYSEXT/Contents/embedded.provisionprofile" ]] || { echo "FAIL: rejected profiles must not be embedded" >&2; exit 1; }

# 5. A profile without a built extension is an error.
rm -rf "$APP/Contents/Library"
if "$SCRIPT" "$APP" "7WLXT3NR37.com.cmuxterm.app.tunnel" "$good" >/dev/null 2>&1; then
  echo "FAIL: accepted a profile with no extension in the bundle" >&2; exit 1
fi

echo "PASS: embed-tunnel-extension-profile.sh"
