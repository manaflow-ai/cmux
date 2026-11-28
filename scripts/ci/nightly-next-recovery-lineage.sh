#!/usr/bin/env bash
# May an earlier nightly-next build be recovered and published to the cmux
# NEXT feed? Run 38868028629 recovered build 3868902633801 from 0664bd98
# (2026-10-14) and published it over newer builds. A recovered build must:
#   1. contain every commit in NIGHTLY_LEGACY_REQUIRED_COMMITS (env REQUIRED,
#      full SHAs, space-separated); unset, empty or malformed refuses, and
#   2. descend from (or equal) the commit the NEXT feed serves now: the
#      cmux-published-sha marker of the channel release body, which "Record
#      verified nightly publication" writes after the feed upload.
#
# Usage: nightly-next-recovery-lineage.sh <owner/repo> <release tag> <commit sha>
#   <commit sha> is the build's commit, or the head of the run that made it
#   (an upper bound: a commit missing from the head is missing from the build).
# Prints one line and exits:
#   0 "ok <commit> served=<sha>"
#   3 "refuse <reason>"   the build must not be recovered or published
#   1 "error <reason>"    the check could not run; callers refuse (fail closed)
set -uo pipefail
repo="${1:-}" tag="${2:-}" sha="${3:-}"
if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || -z "$tag" || ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error usage: $0 <owner/repo> <release tag> <commit sha>"
  exit 1
fi
read -ra required <<<"${REQUIRED:-}"
if [ "${#required[@]}" -eq 0 ]; then
  echo "refuse NIGHTLY_LEGACY_REQUIRED_COMMITS is unset or empty"
  exit 3
fi
for commit in "${required[@]}"; do
  if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo "refuse NIGHTLY_LEGACY_REQUIRED_COMMITS has '$commit', not a full SHA"
    exit 3
  fi
done
if ! body="$(gh api "repos/$repo/releases/tags/$tag" --jq .body 2>&1)"; then
  echo "error could not read release $tag (${body//$'\n'/ })"
  exit 1
fi
served="$(python3 -I "$(dirname "$0")/nightly-publication-marker.py" <<<"$body")"
if [[ ! "$served" =~ ^[0-9a-f]{40}$ ]]; then
  echo "refuse release $tag records no cmux-published-sha, so the served commit is unknown"
  exit 3
fi
# contains <ancestor> <label>: is <ancestor> in $sha?
contains() {
  local status
  # per_page=1: only the status is read; keep the response small.
  if ! status="$(gh api "repos/$repo/compare/$1...$sha?per_page=1" --jq .status 2>&1)"; then
    echo "error could not compare $1 with $sha (${status//$'\n'/ })"
    exit 1
  fi
  case "$status" in
    ahead|identical) ;;
    behind|diverged) echo "refuse $sha does not contain $2 $1"; exit 3 ;;
    *) echo "error unexpected compare status '$status' for $1...$sha"; exit 1 ;;
  esac
}
for commit in "${required[@]}"; do
  contains "$commit" "required commit"
done
contains "$served" "the commit the NEXT feed serves ($tag)"
echo "ok $sha served=$served"
