# shellcheck shell=bash
# Sourced by every Xcode build that reads the managed fleet compilation cache
# (scripts/ci/fleet-compilation-cache.sh) and has no retry of its own: the PR
# Release build (ci-macos.yml release-build) and the nightly cache warmer
# (nightly-steps/refresh-universal-compilation-cache.sh). The nightly's own
# Release build (nightly-steps/app-build-release.sh) keeps the same rule inline.
#
# The fleet cache failed the nightly in four forms in one day (a corrupt
# object, a missing module key, a precompile's "CAS operation failed", a
# compiler crash reading the CAS; runs 42100189059, 42524304475, 42527779911,
# 42535989825), and each text match lost to the next form (#38915, #38988,
# #39047). So a build that used the fleet cache and fails for any reason runs
# once more with CMUX_CI_FLEET_CACHE_OFF=1, which makes
# fleet-compilation-cache.sh hand out the local cache's settings. A real
# compile error fails the retry too: at most one extra build, on a run that is
# red anyway. A build that never reached the fleet cache gets no retry.

# Whether fleet-compilation-cache.sh routes a build to the fleet cache now.
# Usage: cmux_fleet_cache_in_use <scripts/ci dir>
cmux_fleet_cache_in_use() {
  [[ "${CMUX_CI_FLEET_CACHE_OFF:-}" != 1 ]] || return 1
  local settings
  settings="$(bash "$1/fleet-compilation-cache.sh")" || return 1
  [[ $'\n'"$settings" == *$'\nCOMPILATION_CACHE_REMOTE_SERVICE_PATH='* ]]
}

# Run BUILD (a command or shell function that reads its cache settings from
# fleet-compilation-cache.sh), with its output in LOG; on a fleet-cache failure
# run it once more on the local cache. Returns the last build's status.
# Usage: cmux_fleet_cache_build <scripts/ci dir> <log> <build> [arg...]
cmux_fleet_cache_build() {
  local dir=$1 log=$2 fleet=0 status
  shift 2
  cmux_fleet_cache_in_use "$dir" && fleet=1
  # Callers run under set -e; a failed first build must reach the retry.
  if "$@" 2>&1 | tee "$log"; then status=0; else status=${PIPESTATUS[0]}; fi
  if [[ "$status" -ne 0 && "$fleet" -eq 1 ]]; then
    echo "::warning::the build failed on the managed fleet compilation cache (status $status); retrying it once with the local cache"
    if CMUX_CI_FLEET_CACHE_OFF=1 "$@" 2>&1 | tee "$log.retry"; then status=0; else status=${PIPESTATUS[0]}; fi
  fi
  return "$status"
}
