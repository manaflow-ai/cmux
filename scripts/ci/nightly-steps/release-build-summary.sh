#!/usr/bin/env bash
# nightly.yml build-nightly-app "Build nightly app (Release)" (app-build-release.sh): the compile cache's
# last hits line and which cache the build used, into the job summary. Usage: LOG CACHE, where CACHE is
# fleet, unavailable (fleet-compilation-cache.sh stayed local: no fleet socket), cold (decide asked for
# a cold cache) or fallback (the fleet cache failed and the build retried with the local cache).
# Never fails the build.
set -uo pipefail
log="$1" cache="${2:-}"
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || exit 0
# Both of Xcode 26.6's forms: "N hits / M cacheable tasks (P%)" and the compact "N/M cacheable tasks"
# (scripts/ci/build_metrics.py CACHE_SUMMARY_RE).
line="$(grep -oE '[0-9]+ *(hits? *)?/ *[0-9]+ +cacheable tasks?' "$log" 2>/dev/null | tail -n 1)"
{
  if [[ "$line" =~ ^([0-9]+)[^0-9]*/\ *([0-9]+) ]]; then
    hits="${BASH_REMATCH[1]}" tasks="${BASH_REMATCH[2]}"
    percent=0
    ((tasks > 0)) && percent=$((hits * 100 / tasks))
    echo "- compile cache: $hits hits / $tasks cacheable tasks ($percent%), $((tasks - hits)) missed"
  else
    echo "- compile cache: no hits line in the build log"
  fi
  case "$cache" in
    fleet) echo "- cache: fleet cache" ;;
    unavailable) echo "- cache: local cache (the fleet cache was unavailable)" ;;
    cold) echo "- cache: local cache (a cold-cache run)" ;;
    fallback) echo "- cache: local cache after the fleet cache failed" ;;
    *) echo "- cache: unknown" ;;
  esac
} >> "$GITHUB_STEP_SUMMARY" || true
