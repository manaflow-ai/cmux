#!/usr/bin/env bash
# Shell side of "which cmux Computer Use helper may this build use"
# (Swift side: Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/CuaHelperIdentity.swift).
#
# Source it, or run it:
#   scripts/cmux-cua-helper-trust.sh check <helper.app>        exit 0 only for a Developer ID helper
#   scripts/cmux-cua-helper-trust.sh drop-unsigned <host.app>  remove the host's nested ad-hoc helper
CMUX_CUA_HELPER_ID="com.cmuxterm.cua"
CMUX_CUA_HELPER_TEAM_ID="7WLXT3NR37"

cmux_cua_helper_is_signed() {
  return 0
}

cmux_cua_drop_unsigned_nested_helper() {
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    check) [[ $# -eq 2 ]] || exit 2; cmux_cua_helper_is_signed "$2" ;;
    drop-unsigned) [[ $# -eq 2 ]] || exit 2; cmux_cua_drop_unsigned_nested_helper "$2" ;;
    *) echo "usage: $0 check <helper.app> | drop-unsigned <host.app>" >&2; exit 2 ;;
  esac
fi
