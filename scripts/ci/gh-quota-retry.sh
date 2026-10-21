#!/usr/bin/env bash
# gh-quota-retry.sh <command...>: run a gh command; when it fails on the
# repository token's API quota, wait for the quota and run it again.
#
# On 2026-10-21 nightly-next runs 39535920020 and 39536149802 published the
# feed, then failed release notes, deltas and the NIGHTLY-identity copy on
# "API rate limit exceeded for installation" (HTTP 403): the feat-cmux-next
# push flood had used the hour's GITHUB_TOKEN quota. A short retry does not
# help a primary limit, so this waits until the reset GitHub reports
# (`gh api rate_limit` costs no quota), capped by GH_QUOTA_MAX_WAIT seconds
# (default 900) per wait, at most GH_QUOTA_ATTEMPTS runs (default 3). A
# secondary limit ("secondary rate limit") waits 60 s. Any other failure
# exits with the command's status at once. The command's stdout passes
# through unchanged; its stderr is kept and replayed.
set -uo pipefail

[[ $# -gt 0 ]] || { echo "usage: gh-quota-retry.sh <command...>" >&2; exit 2; }
max_wait="${GH_QUOTA_MAX_WAIT:-900}"
attempts="${GH_QUOTA_ATTEMPTS:-3}"
err="$(mktemp)"
trap 'rm -f "$err"' EXIT

for ((attempt = 1; ; attempt++)); do
  "$@" 2>"$err"
  status=$?
  cat "$err" >&2
  [[ $status -ne 0 ]] || exit 0
  if ! grep -qiE 'rate limit exceeded|secondary rate limit' "$err" || (( attempt >= attempts )); then
    exit "$status"
  fi
  if grep -qi 'secondary rate limit' "$err"; then
    wait_s=60
  else
    reset="$(gh api rate_limit --jq '.resources.core.reset' 2>/dev/null || echo 0)"
    now="$(date +%s)"
    wait_s=$(( reset > now ? reset - now + 5 : 60 ))
  fi
  (( wait_s <= max_wait )) || wait_s="$max_wait"
  echo "::warning::GitHub API quota exhausted (attempt $attempt/$attempts); waiting ${wait_s}s before running again" >&2
  sleep "$wait_s" # bounded wait for GitHub's quota reset, not synchronization
done
