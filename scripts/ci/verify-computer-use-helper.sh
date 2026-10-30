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
