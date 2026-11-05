#!/usr/bin/env bash
# nightly.yml build-nightly-app "Build nightly app (Release)" (app-build-release.sh): the compile cache's
# last hits line and which cache the build used, into the job summary. Usage: LOG FALLBACK (1 = the
# fleet cache failed and the build retried with the local cache). Never fails the build.
set -uo pipefail
log="$1" fallback="${2:-0}"
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || exit 0
line="$(grep -oE '[0-9]+ hits / [0-9]+ cacheable tasks( \([0-9]+%\))?' "$log" 2>/dev/null | tail -n 1)"
{
  if [[ "$line" =~ ^([0-9]+)\ hits\ /\ ([0-9]+) ]]; then
    echo "- compile cache: $line, $((BASH_REMATCH[2] - BASH_REMATCH[1])) missed"
  else
    echo "- compile cache: no hits line in the build log"
  fi
  if [[ "$fallback" == 1 ]]; then
    echo "- cache: local cache after the fleet cache failed"
  else
    echo "- cache: fleet cache"
  fi
} >> "$GITHUB_STEP_SUMMARY" || true
