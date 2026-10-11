#!/usr/bin/env bash
# Shell side of "which cmux Computer Use helper may this build use"
# (Swift side: Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/CuaHelperIdentity.swift).
#
# Source it, or run it:
#   scripts/cmux-cua-helper-trust.sh check <helper.app>        exit 0 only for a Developer ID helper
#   scripts/cmux-cua-helper-trust.sh drop-unsigned <host.app>  remove the host's nested ad-hoc helper
CMUX_CUA_HELPER_ID="com.cmuxterm.cua"
CMUX_CUA_HELPER_TEAM_ID="7WLXT3NR37"

# The release helper's designated requirement: the two certificate fields are
# the Developer ID intermediate and leaf markers, so an Apple Development or
# Apple Distribution signature of the same team fails too.
CMUX_CUA_HELPER_REQUIREMENT="=identifier \"$CMUX_CUA_HELPER_ID\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"$CMUX_CUA_HELPER_TEAM_ID\""

# Exit 0 only when the bundle's signature satisfies the Developer ID
# requirement of the release helper. Reads the signature on disk; launches
# nothing and never prompts. An ad-hoc signature has no certificate, so it fails.
cmux_cua_helper_is_signed() {
  local app="$1"
  [[ -d "$app" ]] || return 1
  /usr/bin/codesign --verify --deep --strict -R "$CMUX_CUA_HELPER_REQUIREMENT" "$app" >/dev/null 2>&1 || return 1
}

# A dev build must not carry an ad-hoc com.cmuxterm.cua helper: LaunchServices
# registers nested apps, so `open -b com.cmuxterm.cua` or a drag into Privacy &
# Security can pick it, and a grant to it replaces the release helper's TCC
# row. Removes only "<host>/Contents/Library/cmux Computer Use.app" when its
# bundle id is the helper's and its signature fails the requirement.
cmux_cua_drop_unsigned_nested_helper() {
  local host="$1"
  local helper="$host/Contents/Library/cmux Computer Use.app"
  [[ -d "$helper" && ! -L "$helper" ]] || return 0
  local id
  id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$helper/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$id" == "$CMUX_CUA_HELPER_ID" ]] || return 0
  cmux_cua_helper_is_signed "$helper" && return 0
  /bin/rm -rf -- "$helper"
  rmdir "$host/Contents/Library" 2>/dev/null || true
  echo "Removed the ad-hoc cmux Computer Use helper from $host (dev builds use a release helper or none)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    check) [[ $# -eq 2 ]] || exit 2; cmux_cua_helper_is_signed "$2" ;;
    drop-unsigned) [[ $# -eq 2 ]] || exit 2; cmux_cua_drop_unsigned_nested_helper "$2" ;;
    *) echo "usage: $0 check <helper.app> | drop-unsigned <host.app>" >&2; exit 2 ;;
  esac
fi
