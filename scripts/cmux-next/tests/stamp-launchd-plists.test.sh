#!/usr/bin/env bash
# The release signer keeps the optional launch-time pre-read in stable bundles
# while dropping the development-only server launchd jobs.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
APP="$TMP/cmux.app"
mkdir -p "$APP/Contents/Resources/bin" "$APP/Contents/Resources/libexec"
printf '%s\n' '#!/bin/sh' > "$APP/Contents/Resources/bin/cmux"
printf '%s\n' '#!/bin/sh' > "$APP/Contents/Resources/bin/cmux-launch-preread"
printf '%s\n' '#!/bin/sh' > "$APP/Contents/Resources/libexec/cmux-server-helper"
chmod +x "$APP/Contents/Resources/bin/"* "$APP/Contents/Resources/libexec/"*

write_info() {
  BUNDLE_ID="$1" APP="$APP" python3 - <<'PY'
import os, plistlib
with open(os.path.join(os.environ["APP"], "Contents", "Info.plist"), "wb") as handle:
    plistlib.dump({"CFBundleIdentifier": os.environ["BUNDLE_ID"]}, handle)
PY
}
plist() { python3 - "$1" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as handle:
    print(plistlib.load(handle))
PY
}

write_info com.cmuxterm.app
python3 -I "$ROOT/scripts/ci/release-signer/stamp-launchd-plists.py" "$APP" >/dev/null
[[ ! -e "$APP/Contents/Library/LaunchDaemons/com.cmux.server.helper.plist" ]] || { echo 'stable helper plist kept' >&2; exit 1; }
[[ ! -e "$APP/Contents/Library/LaunchAgents/com.cmux.server.plist" ]] || { echo 'stable server plist kept' >&2; exit 1; }
preread="$APP/Contents/Library/LaunchAgents/com.cmux.launch-preread.plist"
[[ -f "$preread" ]] || { echo 'stable pre-read plist was dropped' >&2; exit 1; }
[[ "$(plist "$preread")" == *"com.cmuxterm.app.launch-preread"* ]] || { echo 'stable pre-read label is wrong' >&2; exit 1; }

write_info com.cmuxterm.app.nightly
printf '%s\n' '#!/bin/sh' > "$APP/Contents/Resources/libexec/cmux-server-helper"
chmod +x "$APP/Contents/Resources/libexec/cmux-server-helper"
python3 -I "$ROOT/scripts/ci/release-signer/stamp-launchd-plists.py" "$APP" >/dev/null
[[ -f "$APP/Contents/Library/LaunchDaemons/com.cmux.server.helper.plist" ]] || { echo 'nightly helper plist missing' >&2; exit 1; }
[[ -f "$APP/Contents/Library/LaunchAgents/com.cmux.server.plist" ]] || { echo 'nightly server plist missing' >&2; exit 1; }
[[ -f "$preread" ]] || { echo 'nightly pre-read plist missing' >&2; exit 1; }
[[ "$(plist "$preread")" == *"com.cmuxterm.app.nightly.launch-preread"* ]] || { echo 'nightly pre-read label is wrong' >&2; exit 1; }
printf 'stamp-launchd-plists: ok\n'
