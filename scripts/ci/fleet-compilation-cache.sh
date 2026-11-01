#!/usr/bin/env bash
# Print one allowlisted Xcode setting per line. Shared by app-host admission
# and nightly Release builds; an absent or unhealthy managed CAS stays local.
set -euo pipefail

fleet_cache_setting=(
    # Keep cache keys stable when a PR runner's checkout and DerivedData live
    # under a different absolute root than the fleet CAS writer.
    SWIFT_ENABLE_PREFIX_MAPPING=YES
    CLANG_ENABLE_PREFIX_MAPPING=YES
    SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=YES
    CLANG_ENABLE_PROJECT_PREFIX_MAPPING=YES
    # Xcode 26.6 emits one bounded remark per cache query. The build metrics
    # receipt turns those remarks into cacheable-task and hit counters.
    COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES
)
# Keep mapping and diagnostics when caching is disabled, as admission did.
if [ "${CMUX_CI_DISABLE_COMPILATION_CACHE:-}" != 1 ]; then
  fleet_cas_root="${CMUX_FLEET_CAS_ROOT:-/Users/Shared/cmux-build-fleet/xcode}"
  fleet_cas_settings="${CMUX_FLEET_CAS_SETTINGS:-$fleet_cas_root/bin/fleet-cas-settings.sh}"
  fleet_cas_socket="${CMUX_FLEET_CAS_SOCKET:-$fleet_cas_root/fleet-cas.sock}"
  if [ -x "$fleet_cas_settings" ] && [ -S "$fleet_cas_socket" ]; then
    fleet_settings=''
    fleet_settings="$("$fleet_cas_settings" "$fleet_cas_socket" 2>/dev/null | head -n 8)" || fleet_settings=''
    fleet_plugin_ok=0
    fleet_remote_ok=0
    while IFS= read -r setting; do
      case "$setting" in
        COMPILATION_CACHE_ENABLE_PLUGIN=YES) fleet_plugin_ok=1 ;;
        COMPILATION_CACHE_REMOTE_SERVICE_PATH=/*) fleet_remote_ok=1 ;;
        COMPILATION_CACHE_CAS_PATH=/*) ;;
      esac
    done <<< "$fleet_settings"
    if [ "$fleet_plugin_ok" -eq 1 ] && [ "$fleet_remote_ok" -eq 1 ]; then
      fleet_cache_setting+=("COMPILATION_CACHE_CAS_PATH=$fleet_cas_root/cas")
      while IFS= read -r setting; do
        case "$setting" in
          COMPILATION_CACHE_ENABLE_PLUGIN=YES|COMPILATION_CACHE_REMOTE_SERVICE_PATH=/*)
            fleet_cache_setting+=("$setting")
            ;;
        esac
      done <<< "$fleet_settings"
    fi
  fi
fi
printf '%s\n' "${fleet_cache_setting[@]}"
