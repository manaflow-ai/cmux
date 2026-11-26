#!/usr/bin/env bash
# land_tier_status_post.sh: posts the land tier's `cmux/land-tier` commit status STATE at SHA of REPO.
# pr-router.yml's route job runs it, and its `land tier status` job runs it again when that post got through on no
# token (tests/test_ci_land_tier_status_post.py).
#
# Env: REPO, SHA, STATE (success or pending), RUN_URL; the tokens APP_TOKEN (the cmux-bot App), POOL_TOKENS
# (space-separated, optional) and JOB_TOKEN (the job's GITHUB_TOKEN), tried in that order, an empty one skipped;
# LAND_STATUS_WAIT_S, the most this may sleep in all (default 0: one try of each token).
#
# Why: each token's REST budget is an installation's hour. When every one was spent, the post used to sleep 20 s and
# 40 s on a fixed schedule whatever GitHub said, then give up under continue-on-error: run 45900568467 (cmux#57321,
# 2026-11-26 21:48Z) computed success, both tokens answered "API rate limit exceeded for installation" three
# times, the run read green, cmux/land-tier stayed the cheap tier's `pending` and land stopped the PR as
# checks_stuck after 4.1 h. Now a refused token's own answer says when it can post again (Retry-After, or
# X-RateLimit-Reset once X-RateLimit-Remaining is 0): this sleeps until the first token frees up when that falls
# inside LAND_STATUS_WAIT_S, else stops at once (no sleep that cannot end in a post), and exits 1 with a warning.
set -uo pipefail

: "${REPO:?}" "${SHA:?}" "${STATE:?}"
wait_s=${LAND_STATUS_WAIT_S:-0}

if [ "$STATE" = success ]; then
  # GitHub refuses a status description over 140 characters ("Validation failed: Description is too long"),
  # and the post below caps it there too: run 45839458055 (2026-11-26 14:29Z) left this status unposted.
  desc="Land tier runs here: full, affected (full tier hourly on feat-cmux-next), or carried from the base merge's head"
else
  desc="Cheap tier: the full tier runs when ready-to-land or full-ci is added"
fi

out=$(mktemp)
err=$(mktemp)
trap 'rm -f "$out" "$err"' EXIT
# header NAME: the value of response header NAME in $out (gh api --include prints the status line and headers first).
header() { tr -d '\r' < "$out" | sed -n "1,/^\$/{s/^$1:[[:space:]]*//Ip}" | head -n 1; }

deadline=$(( $(date +%s) + wait_s ))
for round in 1 2 3 4 5 6; do
  wake=0  # the first moment a refused token may post again; 0: none will
  # shellcheck disable=SC2086 # POOL_TOKENS is a space-separated list
  for token in "${APP_TOKEN:-}" ${POOL_TOKENS:-} "${JOB_TOKEN:-}"; do
    [ -n "$token" ] || continue
    if GH_TOKEN="$token" gh api --include "repos/$REPO/statuses/$SHA" -f state="$STATE" -f context=cmux/land-tier \
        -f description="${desc:0:140}" -f target_url="${RUN_URL:-}" >"$out" 2>"$err"; then
      echo "cmux/land-tier ($STATE) posted at $SHA"
      exit 0
    fi
    cat "$err" >&2
    now=$(date +%s)
    code=$(tr -d '\r' < "$out" | sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p')
    retry_after=$(header retry-after | tr -cd 0-9)
    reset=$(header x-ratelimit-reset | tr -cd 0-9)
    if [ -n "$retry_after" ]; then
      at=$(( now + retry_after ))           # a secondary limit, or a 429 saying how long
    elif [ "$(header x-ratelimit-remaining | tr -cd 0-9)" = 0 ] && [ -n "$reset" ]; then
      at=$(( reset + 1 ))                    # the token's hour is spent: it posts again at the reset
    elif [ -z "$code" ] || [ "$code" -ge 500 ] || [ "$code" = 403 ] || [ "$code" = 429 ]; then
      at=$(( now + 5 * round ))              # no answer, a 5xx or a refusal without a time: a short backoff
    else
      continue                               # another 4xx (a bad request): no wait makes it post
    fi
    if [ "$wake" = 0 ] || [ "$at" -lt "$wake" ]; then wake=$at; fi
  done
  now=$(date +%s)
  if [ "$wake" = 0 ] || [ "$wake" -gt "$deadline" ]; then
    [ "$wake" = 0 ] || echo "the first token frees up in $(( wake - now )) s, past this post's ${wait_s} s bound"
    break
  fi
  [ "$wake" -le "$now" ] || sleep "$(( wake - now ))"
done
echo "::warning::cmux/land-tier ($STATE) was not posted at $SHA: its land waits on the last state posted there"
exit 1
