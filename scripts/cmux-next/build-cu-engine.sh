#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds "cmux CU Engine.app" (bundle id com.cmuxterm.cu.engine.dev): the
# release cmux-cu-service from Packages/macOS/CmuxComputerUseEngine in a
# minimal accessory app bundle, zipped to OUT. Unsigned; sign it on the Mac
# that will run it (codesign --sign IDENTITY), so its Accessibility and
# Screen Recording grants attach to a stable designated requirement.
# Run on a fleet Mac (cmux-ci run), never on a laptop.
#
#   build-cu-engine.sh [--out FILE]   (default .build/cu-engine/cmux-cu-engine.zip)
set -euo pipefail
if [[ $OSTYPE == darwin* ]] && ((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 501)); then BASH_COMPAT=50; fi  # macOS heredoc pipe hang: tests/test_bash_heredoc_pipe_guard.py
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
out="$repo_root/.build/cu-engine/cmux-cu-engine.zip"
while (( $# )); do
  case "$1" in
    --out) out="${2:?}"; shift 2 ;;
    *) echo "usage: build-cu-engine.sh [--out FILE]" >&2; exit 2 ;;
  esac
done
package="$repo_root/Packages/macOS/CmuxComputerUseEngine"
APP_NAME="cmux CU Engine"
BUNDLE_ID="com.cmuxterm.cu.engine.dev"
EXECUTABLE="cmux-cu-service"

(cd "$package" && swift build -c release --arch arm64 --product "$EXECUTABLE" < /dev/null)
bin="$(cd "$package" && swift build -c release --arch arm64 --show-bin-path)/$EXECUTABLE"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
app="$work/$APP_NAME.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/$EXECUTABLE"
version="0.1.$(git -C "$repo_root" rev-parse --short=7 HEAD 2>/dev/null || echo dev)"
/usr/bin/python3 -I - "$app/Contents/Info.plist" "$APP_NAME" "$BUNDLE_ID" "$EXECUTABLE" "$version" <<'PY'
import plistlib, sys
path, name, bundle_id, executable, version = sys.argv[1:6]
plistlib.dump({
    "CFBundleName": name, "CFBundleDisplayName": name, "CFBundleIdentifier": bundle_id,
    "CFBundleExecutable": executable, "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version, "CFBundleVersion": version,
    "LSMinimumSystemVersion": "14.0",
    # Accessory: no Dock icon, no menu bar, never activates.
    "LSUIElement": True, "LSBackgroundOnly": True,
    "NSAccessibilityUsageDescription": "cmux Computer Use reads and operates the apps an agent is asked to use.",
    "NSScreenCaptureUsageDescription": "cmux Computer Use takes screenshots of the windows an agent is asked to use.",
}, open(path, "wb"))
PY
mkdir -p "$(dirname "$out")"
rm -f "$out"
(cd "$work" && /usr/bin/ditto -c -k --keepParent "$APP_NAME.app" "$out")
echo "built $out ($(du -h "$out" | cut -f1)) version $version"
