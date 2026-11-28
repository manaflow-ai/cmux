#!/usr/bin/env bash
# Start app-ffi-repin.yml on feat-cmux-next after a re-pin failed or was cancelled.
#
# The run's installation token shares one rate limit with every other job. On 2026-11-27 run 46086089622's re-pin
# stopped on HTTP 403 at 00:25Z, and this dispatch then spent all five fixed tries (0, 60, 120, 180, 180 s) inside the
# same exhausted hour: the pin sat 131 min behind main and three NOW deploy-lag rows went red. A fixed backoff cannot
# outlast a limit that resets up to an hour away.
#
# GET /rate_limit does not count against the limit, so a refusal reads the core budget there: at 0 remaining the next
# try waits for the reset (plus 2 s); with budget left (a transient error) it backs off 15, 30, 60 s. The wait ends at
# DISPATCH_MAX_WAIT_S (default 3900, a bit over one limit window); a reset past that fails now instead of sleeping.
set -u

max_wait="${DISPATCH_MAX_WAIT_S:-3900}"
start="$(date +%s)"
attempt=0
while :; do
  if gh workflow run app-ffi-repin.yml --ref feat-cmux-next; then
    exit 0
  fi
  attempt=$((attempt + 1))
  elapsed=$(($(date +%s) - start))
  left=$((max_wait - elapsed))
  remaining="" reset=""
  read -r remaining reset < <(gh api rate_limit --jq '"\(.resources.core.remaining) \(.resources.core.reset)"' 2>/dev/null) || true
  if [[ "$remaining" == 0 && "$reset" =~ ^[0-9]+$ ]]; then
    wait_s=$((reset - $(date +%s) + 2))
    ((wait_s > 0)) || wait_s=2
    why="the limit resets in ${wait_s}s"
  else
    wait_s=$((15 << (attempt > 3 ? 2 : attempt - 1)))
    why="backoff (budget left: ${remaining:-unread})"
  fi
  if ((wait_s > left)); then
    echo "::error title=Re-pin dispatch::dispatch failed and ${why}, past the ${max_wait}s bound (${elapsed}s waited)"
    exit 1
  fi
  echo "re-pin dispatch failed (attempt $attempt); asking again in ${wait_s}s: $why"
  sleep "$wait_s"
done
