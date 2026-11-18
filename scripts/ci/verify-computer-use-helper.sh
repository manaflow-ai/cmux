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

# The Screen Sharing helper (plans/cmux-next/screen-sharing-helper.md), when the
# app carries one: "Contents/Library/<app name> Screen Sharing.app" with bundle id
# <app bundle id>.screen-sharing and executable cmux-screen-sharing
# (scripts/cmux-next/bundle-screen-sharing-helper.sh). cmux copies it out of the
# app as it does the Computer Use helper, so a signed one must carry the team's
# Developer ID signature and the hardened runtime. Once signed, its id is the
# app's own plus .screen-sharing: a re-identified copy of the app
# (stable-next-identity.sh, nightly-next-legacy-identity.sh) re-stamps it
# (sign-cmux-bundle.sh), so no two channels share its grants.
for share in "$app/Contents/Library/"*" Screen Sharing.app"; do
  [[ -e "$share" || -L "$share" ]] || continue
  name="${share##*/}"
  [[ -d "$share" && ! -L "$share" ]] || fail "$name is not a directory"
  share_id="$(python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb")).get("CFBundleIdentifier", ""))' \
    "$share/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$share_id" == ?*.screen-sharing ]] || fail "$name has bundle id '${share_id}', expected <app bundle id>.screen-sharing"
  [[ -f "$share/Contents/MacOS/cmux-screen-sharing" && -x "$share/Contents/MacOS/cmux-screen-sharing" ]] \
    || fail "$name has no executable Contents/MacOS/cmux-screen-sharing"
  if [[ "$mode" == signed ]]; then
    app_id="$(python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb")).get("CFBundleIdentifier", ""))' \
      "$app/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$share_id" == "$app_id.screen-sharing" ]] \
      || fail "$name has bundle id '$share_id', expected $app_id.screen-sharing (bundle-screen-sharing-helper.sh --stamp)"
    # The Developer ID requirement cmux-cua-helper-trust.sh states for the
    # Computer Use helper, for this helper's identifier: an ad hoc, Apple
    # Development or Apple Distribution signature fails.
    share_requirement="=identifier \"$share_id\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"7WLXT3NR37\""
    /usr/bin/codesign --verify --strict -R "$share_requirement" "$share" >/dev/null 2>&1 \
      || fail "$name fails the $share_id Developer ID requirement"
    /usr/bin/codesign -d --verbose=2 "$share" 2>&1 | grep -q 'flags=.*runtime' \
      || fail "$name is not signed with the hardened runtime"
  fi
  echo "ok: $share ($mode)"
done
