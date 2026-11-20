#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# DEV and bench builds embed a team-signed arm64 helper from the asset store.
# Release builds assemble their own helper with the Release bundle ID and architectures.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
library="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}/Contents/Library"
name="cmux Computer Use (dev).app"
dest="$library/$name"
stamp="${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}/embed-cmux-remote-dev.stamp"
# An incremental Xcode build may still have the old product at its former output path.
rm -rf "$library/cmux Remote (dev).app"

skip() {
  echo "note: not embedding $name: $1"
  rm -rf "$dest"
  rm -f "$stamp"
  exit 0
}
if [[ "${CONFIGURATION:-}" == Release && " ${OTHER_SWIFT_FLAGS:-} " != *" -DCMUX_BENCH_HOOKS "* ]]; then
  skip "the release assembles cmux Computer Use.app separately"
fi
[[ "${CMUX_NEXT_SKIP_CMUX_REMOTE:-0}" == 1 ]] && skip "CMUX_NEXT_SKIP_CMUX_REMOTE=1"
[[ " ${ARCHS:-arm64} " == *" arm64 "* ]] || skip "ARCHS=${ARCHS:-} has no arm64"
pin="${CMUX_NEXT_CMUX_REMOTE_PIN:-$SCRIPT_DIR/cmux-remote-dev.pin.json}"
required="${CMUX_NEXT_REQUIRE_CMUX_REMOTE:-0}"
if [[ ! -f "$pin" ]]; then
  [[ "$required" == 1 ]] && { echo "error: $name requires pin file $pin" >&2; exit 1; }
  skip "no pin file $pin"
fi
# The old pin authenticates a different signed app. Never unpack it into the new bundle location.
pin_id="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["bundle_id"])' "$pin")"
if [[ "$pin_id" == com.cmuxterm.remote.dev && "$required" != 1 ]]; then
  echo "warning: $pin still identifies the old DEV helper" >&2
  skip "waiting for the signed com.cmuxterm.cua.dev artifact"
fi
[[ "$pin_id" == com.cmuxterm.cua.dev ]] || { echo "error: $pin identifies $pin_id; expected com.cmuxterm.cua.dev" >&2; exit 1; }
args=(--optional)
[[ "$required" == 1 ]] && args=()
zip="$("$SCRIPT_DIR/ensure-signed-pinned-asset.sh" "$pin" ${args[@]+"${args[@]}"})"
[[ -n "$zip" ]] || skip "the pinned helper is unavailable"
want="$(shasum -a 256 "$zip" | awk '{print $1}')"
requirement='identifier "com.cmuxterm.cua.dev" and anchor apple generic and certificate leaf[subject.OU] = "7WLXT3NR37"'
if [[ -f "$stamp" && "$(cat "$stamp")" == "$want" ]] && codesign --verify --strict --deep -R="$requirement" "$dest" 2>/dev/null; then
  echo "note: $name already embedded ($want)"
  exit 0
fi

mkdir -p "$library"
work="$(mktemp -d "$library/.computer-use.XXXXXX")"
trap 'rm -rf "$work"' EXIT
ditto -x -k "$zip" "$work"
helper="$work/$name"
[[ -d "$helper" && ! -L "$helper" ]] || { echo "error: $zip has no $name" >&2; exit 1; }
codesign --verify --strict --deep -R="$requirement" "$helper"
codesign --verify --strict -R="$requirement" "$helper/Contents/MacOS/cmux-screen-sharing"
python3 -I - "$helper/Contents/Info.plist" <<'PYPLIST'
import plistlib
import sys

with open(sys.argv[1], "rb") as file:
    info = plistlib.load(file)
if (info.get("CFBundleIdentifier"), info.get("CFBundleExecutable")) != ("com.cmuxterm.cua.dev", "cmux-remote"):
    sys.exit("error: unexpected DEV helper bundle identifier or executable")
PYPLIST
for file in MacOS/cmux-remote MacOS/cmux-screen-sharing Frameworks/libcmux_computer_use.dylib Frameworks/libWebRTC.dylib; do
  [[ -f "$helper/Contents/$file" ]] || { echo "error: $name is missing $file" >&2; exit 1; }
done
python3 -I "$SCRIPT_DIR/../ci/macho_minos.py" scan "$helper" --floor "${MACOSX_DEPLOYMENT_TARGET:-14.0}"
if [[ -n "$(find "$helper" -name '*.framework' -type d -print)" ]]; then
  echo "error: $name contains a nested framework" >&2; exit 1
fi
rm -rf "$dest"
mv "$helper" "$dest"
mkdir -p "$(dirname "$stamp")"
echo "$want" > "$stamp"
echo "note: embedded $name sha256 $want"
