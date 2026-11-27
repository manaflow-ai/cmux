#!/usr/bin/env bash
# Wraps a built cmux-remote-browser-host binary (scripts/ci/cmux-remote-browser-host-build.sh
# artifact) into a standalone app bundle with its own copy of the CEF fork framework and
# its helper apps (layout: remote-browser-host-layout.sh). No compiler: runs on the GUI
# host (cmux-lawrence-2). DEV cmux-next apps embed the host without a CEF copy instead
# (embed-remote-browser-host.sh).
#   scripts/cmux-next/bundle-remote-browser-host.sh BINARY CEF_PATH OUT.app
# Then: OUT.app/Contents/MacOS/cmux-remote-browser-host --smoke OUT_DIR
set -euo pipefail
bin="${1:?usage: bundle-remote-browser-host.sh BINARY CEF_PATH OUT.app}"
cef="${2:?CEF_PATH}"
app="${3:?OUT.app}"
fw="Chromium Embedded Framework.framework"
[[ -f "$bin" && -d "$cef/$fw" ]] || { echo "error: need the binary and $cef/$fw" >&2; exit 2; }
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remote-browser-host-layout.sh"
rm -rf "$app"
rbh_write_bundle "$bin" "$app"
# Release assets are stripped, which leaves their signatures invalid: re-sign ad hoc.
cp -R "$cef/$fw" "$app/Contents/Frameworks/"
find "$app/Contents/Frameworks/$fw" -name '*.dylib' -exec codesign --force --sign - {} \; 2>/dev/null
codesign --force --sign - "$app/Contents/Frameworks/$fw" 2>/dev/null
rbh_sign "$app" - 2>/dev/null
echo "$app"
