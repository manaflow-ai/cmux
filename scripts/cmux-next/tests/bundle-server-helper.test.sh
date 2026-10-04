#!/usr/bin/env bash
# The "Bundle server helper" Xcode phase must not depend on the app's
# processed Info.plist: Xcode may write it after the script phases, so a
# rebuild of an existing tag failed with "Print: Entry, ':CFBundleIdentifier',
# Does Not Exist". The phase names the build's own PRODUCT_BUNDLE_IDENTIFIER.
# swiftc is a stub here: no compiler, no network, no signing.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/build/app.app/Contents/MacOS" "$TMP/temp"
cat > "$TMP/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
# xcrun swiftc ... -o <out> ...: create every -o / -emit-module-path output.
shift
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" || "$prev" == "-emit-module-path" ]]; then mkdir -p "$(dirname "$arg")"; : > "$arg"; fi
  prev="$arg"
done
STUB
chmod +x "$TMP/bin/xcrun"
run() {
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" TARGET_BUILD_DIR="$TMP/build" WRAPPER_NAME=app.app \
    TARGET_TEMP_DIR="$TMP/temp" SRCROOT="$ROOT" ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CONFIGURATION=Debug \
    PRODUCT_BUNDLE_IDENTIFIER=com.cmuxterm.app.debug.testtag \
    /bin/bash "$ROOT/scripts/cmux-next/bundle-server-helper.sh" 2>&1
}
# No processed Info.plist yet (Xcode writes it later on a rebuild).
if ! out=$(run); then printf 'phase failed without the processed Info.plist:\n%s\n' "$out" >&2; exit 1; fi
plist="$TMP/build/app.app/Contents/Library/LaunchDaemons/com.cmux.server.helper.plist"
label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist")
[[ "$label" == "com.cmuxterm.app.debug.testtag.server-helper" ]] || { echo "label: $label" >&2; exit 1; }
# A stale processed Info.plist from another bundle id does not win.
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.example.stale' "$TMP/build/app.app/Contents/Info.plist" >/dev/null
run >/dev/null
label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist")
[[ "$label" == "com.cmuxterm.app.debug.testtag.server-helper" ]] || { echo "stale label: $label" >&2; exit 1; }
printf 'bundle-server-helper tests: ok\n'
