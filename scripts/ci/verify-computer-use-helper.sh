#!/usr/bin/env bash
# Check that a cmux app carries the Computer Use helper onboarding grants
# (cx-urd.6). Onboarding and the legacy driver only use
# "Contents/Library/cmux Computer Use.app" with bundle id com.cmuxterm.cua and
# the team's Developer ID signature (CuaHelperIdentity.swift,
# scripts/cmux-cua-helper-trust.sh); without one the app offers no grant.
#
# Usage:
#   scripts/ci/verify-computer-use-helper.sh layout <app>   before signing
#   scripts/ci/verify-computer-use-helper.sh signed <app>   after Codesign
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/cmux-cua-helper-trust.sh
source "$ROOT/scripts/cmux-cua-helper-trust.sh"
mode="${1:-}"
app="${2:-}"
if [[ $# -ne 2 || ( "$mode" != layout && "$mode" != signed ) ]]; then
  echo "usage: $0 layout|signed <app>" >&2
  exit 2
fi

helper="$app/Contents/Library/cmux Computer Use.app"
fail() {
  echo "error: $app: $*" >&2
  exit 1
}

[[ -d "$helper" && ! -L "$helper" ]] || fail "missing Contents/Library/cmux Computer Use.app (scripts/build-cmux-cua.sh --helper-app)"
id="$(python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb")).get("CFBundleIdentifier", ""))' \
  "$helper/Contents/Info.plist" 2>/dev/null || true)"
[[ "$id" == com.cmuxterm.cua ]] || fail "cmux Computer Use.app has bundle id '${id}', expected com.cmuxterm.cua"
[[ -f "$helper/Contents/MacOS/cmux-cua" && -x "$helper/Contents/MacOS/cmux-cua" ]] \
  || fail "cmux Computer Use.app has no executable Contents/MacOS/cmux-cua"

if [[ "$mode" == signed ]]; then
  "$ROOT/scripts/cmux-cua-helper-trust.sh" check "$helper" \
    || fail "cmux Computer Use.app fails the com.cmuxterm.cua Developer ID requirement (scripts/cmux-cua-helper-trust.sh)"
fi
echo "ok: $helper ($mode)"

# One permission identity for screen sharing and computer use (Lawrence: "ensure screen sharing +
# computer use uses same app for permissions"): the screen sharing executable ships inside this
# helper, Contents/MacOS/cmux-screen-sharing, signed with the helper's identifier
# (scripts/cmux-next/bundle-screen-sharing-helper.sh --into-computer-use). The app's
# Contents/Library holds no other app: each would be its own Screen Recording and Accessibility
# row in System Settings, asked for and granted apart from "cmux Computer Use".
for other in "$app/Contents/Library/"*.app; do
  [[ -e "$other" || -L "$other" ]] || continue
  [[ "$other" != "$helper" ]] || continue
  other_id="$(python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb")).get("CFBundleIdentifier", ""))' \
    "$other/Contents/Info.plist" 2>/dev/null || true)"
  fail "Contents/Library/${other##*/} (${other_id:-no bundle id}) is a second permission identity beside cmux Computer Use.app (com.cmuxterm.cua); the screen sharing executable belongs inside the Computer Use helper (bundle-screen-sharing-helper.sh --into-computer-use)"
done

share="$helper/Contents/MacOS/cmux-screen-sharing"
if [[ -e "$share" || -L "$share" ]]; then
  [[ -f "$share" && ! -L "$share" && -x "$share" ]] || fail "cmux Computer Use.app/Contents/MacOS/cmux-screen-sharing is not an executable file"
  if [[ "$mode" == signed ]]; then
    # The Computer Use helper's Developer ID requirement (scripts/cmux-cua-helper-trust.sh),
    # for the nested executable too: on a macOS that checks the process by its own signature,
    # it is then the same com.cmuxterm.cua row. An ad hoc, Apple Development or other
    # identifier fails.
    /usr/bin/codesign --verify --strict -R "$CMUX_CUA_HELPER_REQUIREMENT" "$share" >/dev/null 2>&1 \
      || fail "cmux Computer Use.app/Contents/MacOS/cmux-screen-sharing fails the com.cmuxterm.cua Developer ID requirement (sign it with --identifier com.cmuxterm.cua before the helper)"
    /usr/bin/codesign -d --verbose=2 "$share" 2>&1 | grep -q 'flags=.*runtime' \
      || fail "cmux Computer Use.app/Contents/MacOS/cmux-screen-sharing is not signed with the hardened runtime"
  fi
  echo "ok: $share ($mode)"
fi
