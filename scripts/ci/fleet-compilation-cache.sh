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
# CMUX_CI_FLEET_CACHE_OFF=1 is a build's one retry after it failed on the fleet
# cache (lib/fleet-cache-fallback.sh): the same settings on the local cache.
if [ "${CMUX_CI_DISABLE_COMPILATION_CACHE:-}" != 1 ] && [ "${CMUX_CI_FLEET_CACHE_OFF:-}" != 1 ]; then
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
    # On the writer host (its fleet-cas.env names FLEET_CAS_SIGN_KEY) the node signs every entry it is handed, and
    # the store takes it. So a GitHub job there may use the node only as a trusted nightly: manaflow-ai/cmux's
    # nightly.yml on a push to, or a dispatch on, main or nightly-next, with the job's opt-in
    # (CMUX_FLEET_CAS_TRUSTED_WRITER=1). Any other job, including a PR or fork build, keeps the local cache and
    # signs nothing. Such a nightly uses its own local CAS, never $fleet_cas_root/cas: the catch-up fill empties
    # that one at its start (fleet-cas-writer-build.sh), and a fill beside a nightly on one CAS broke four
    # nightlies (cmuxterm-hq#8063). Outside GitHub Actions (the fill itself) nothing changes.
    fleet_cas_env="${CMUX_FLEET_CAS_ENV:-$fleet_cas_root/fleet-cas.env}"
    fleet_local_cas="$fleet_cas_root/cas"
    if [ "${GITHUB_ACTIONS:-}" = true ] && [ -f "$fleet_cas_env" ] && grep -q '^FLEET_CAS_SIGN_KEY=.' "$fleet_cas_env"; then
      fleet_trusted=0
      if [ "${CMUX_FLEET_CAS_TRUSTED_WRITER:-}" = 1 ] && [ "${GITHUB_REPOSITORY:-}" = manaflow-ai/cmux ]; then
        case "${GITHUB_EVENT_NAME:-}/${GITHUB_REF:-}" in
          push/refs/heads/main|push/refs/heads/nightly-next|workflow_dispatch/refs/heads/main|workflow_dispatch/refs/heads/nightly-next)
            [ "${GITHUB_WORKFLOW_REF:-}" != "manaflow-ai/cmux/.github/workflows/nightly.yml@$GITHUB_REF" ] || fleet_trusted=1
            ;;
        esac
      fi
      if [ "$fleet_trusted" -eq 1 ]; then
        fleet_local_cas="${CMUX_FLEET_CAS_WRITER_LOCAL_CAS:-$HOME/Library/Caches/cmux-nightly/fleet-cas-local}"
        echo "fleet-compilation-cache: trusted nightly on the writer host: writing through the signing node, local CAS $fleet_local_cas" >&2
      else
        echo "fleet-compilation-cache: the writer host's node signs what it is handed; ${GITHUB_EVENT_NAME:-?} on ${GITHUB_REF:-?} is not a trusted nightly, so this build keeps the local cache" >&2
        fleet_plugin_ok=0
      fi
    fi
    if [ "$fleet_plugin_ok" -eq 1 ] && [ "$fleet_remote_ok" -eq 1 ]; then
      fleet_cache_setting+=("COMPILATION_CACHE_CAS_PATH=$fleet_local_cas")
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
