#!/usr/bin/env bash
# gh-quota-retry.sh <command...>: run a gh command; when it fails on the
# repository token's API quota, wait for the quota and run it again.
#
# On 2026-10-21 nightly-next runs 39535920020 and 39536149802 published the
# feed, then failed release notes, deltas and the NIGHTLY-identity copy on
# "API rate limit exceeded for installation" (HTTP 403): the feat-cmux-next
# push flood had used the hour's GITHUB_TOKEN quota.
#
# A failure whose stderr names a rate limit is run again: after the core
# quota's reset when `gh api rate_limit` (free) says none is left, otherwise
# (a secondary limit, or the quota could not be read) after 60 s. One wait is
# at most GH_QUOTA_MAX_WAIT seconds (default 600), and all waits of one call
# end by GH_QUOTA_DEADLINE (epoch seconds, optional; a job sets it once so
# several calls share one budget). GH_QUOTA_ATTEMPTS (default 2) runs at most.
# Any other failure exits with the command's status at once.
#
# Output: each attempt's stdout is held and printed only for the attempt that
# ends the call (success or the last failure), so `x="$(gh-quota-retry.sh gh
# api ...)"` never captures the error body of a failed attempt (gh prints it
# on stdout). stderr streams live and is also kept to match the limit text.
set -uo pipefail

[[ $# -gt 0 ]] || { echo "usage: gh-quota-retry.sh <command...>" >&2; exit 2; }
max_wait="${GH_QUOTA_MAX_WAIT:-600}"
attempts="${GH_QUOTA_ATTEMPTS:-2}"
deadline="${GH_QUOTA_DEADLINE:-}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for ((attempt = 1; ; attempt++)); do
  # stdout to the file (fd 3); stderr through tee, in a pipe, so it has all
  # been written before grep reads it (pipefail: the status is the command's).
  { "$@" 2>&1 1>&3 3>&- | tee "$tmp/err" >&2; } 3>"$tmp/out"
  status=$?
  if [[ $status -eq 0 ]] || ! grep -qiE 'rate limit' "$tmp/err" || (( attempt >= attempts )); then
    cat "$tmp/out"
    exit "$status"
  fi
  wait_s=60
  remaining="$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null)"
  reset="$(gh api rate_limit --jq '.resources.core.reset' 2>/dev/null)"
  now="$(date +%s)"
  if [[ "$remaining" == 0 && "$reset" =~ ^[0-9]+$ ]] && (( reset > now )); then
    wait_s=$(( reset - now + 5 ))
  fi
  (( wait_s <= max_wait )) || wait_s="$max_wait"
  if [[ "$deadline" =~ ^[0-9]+$ ]]; then
    left=$(( deadline - now ))
    if (( left <= 0 )); then
      echo "::warning::GitHub API rate limit; the job's quota-wait budget is used up" >&2
      cat "$tmp/out"
      exit "$status"
    fi
    (( wait_s <= left )) || wait_s="$left"
  fi
  echo "::warning::GitHub API rate limit (attempt $attempt/$attempts); waiting ${wait_s}s before running again" >&2
  sleep "$wait_s" # bounded wait for GitHub's quota reset, not synchronization
done
