#!/bin/bash
# Re-run a finished, cancelled nightly.yml attempt so its runners are picked fresh.
#
#   nightly_next_rerun.sh REPO RUN_ID ATTEMPT HEAD_SHA WHAT
# WHAT names the run in messages ("the tip 1f0f687b2f32's run 40771197361").
# Callers: nightly_next_cancelled_tip.sh (the tip's push run) and nightly_next_stuck_run.sh (a
# dispatch on nightly-next it cancelled). Needs gh (GH_TOKEN with actions: write) and python3.
#
# A re-run of failed jobs keeps pick-nightly-build-runner's outputs from the earlier attempt, so
# the jobs that take their runner from that pick take its Blacksmith label again (nightly.yml takes
# the owned pick only when it was made for the run's own attempt). That is right after a refusal,
# and wrong when the earlier attempt's label was in outage. So the attempt's jobs that ended
# cancelled or failed with no runner ever assigned (on any label: macOS, Linux or owned) are read,
# and when one of them takes its runner from the picker, pick-nightly-build-runner is re-run instead
# (GitHub re-runs a job and every job that needs it), so the picker chooses fresh. That is done only
# when scripts/ci/nightly_repick.py (owned_pool_rescue.repick_job(), the rescue's own rule) finds it
# safe: every failed job needs the picker, and a finished job it would build again uploads only with
# `overwrite: true`. A whole re-run is never sent: it would repeat jobs whose fixed-name uploads then
# fail. Otherwise, or if a read fails, the failed jobs are re-run: GitHub creates them again, and
# each evaluates its runs-on against the current runner variables. A job whose runs-on is a literal
# label goes back to that label; moving it is the runner set's failover, not this script's.
set -euo pipefail

repo="${1:?usage: nightly_next_rerun.sh REPO RUN_ID ATTEMPT HEAD_SHA WHAT}"
id="${2:?}"
attempt="${3:?}"
head_sha="${4:?}"
what="${5:-run $id}"

# Jobs of that attempt that ended with no runner: name<TAB>labels.
unserved_filter='select((.conclusion == "cancelled" or .conclusion == "failure") and ((.runner_name // "") == "")) | "\(.name)\t\((.labels // []) | join(","))"'
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
unserved=""
if gh api --paginate "repos/$repo/actions/runs/$id/attempts/$attempt/jobs?per_page=100" --jq '.jobs[]' >"$scratch/jobs"; then
  unserved="$(jq -r "$unserved_filter" "$scratch/jobs")" || unserved=""
else
  echo "$what: could not read attempt $attempt's jobs; re-running its failed jobs"
fi
# The picker job to re-run, when nightly.yml at the run's head says that is useful and safe.
picker=""
if [[ -n "$unserved" ]]; then
  cut -f1 <<<"$unserved" >"$scratch/unserved"
  if gh api "repos/$repo/contents/.github/workflows/nightly.yml?ref=$head_sha" --jq .content | base64 -d >"$scratch/nightly.yml"; then
    picker="$(python3 "$(dirname "$0")/nightly_repick.py" "$scratch/nightly.yml" "$scratch/jobs" "$scratch/unserved" 2>"$scratch/why")" || picker=""
    [[ "$picker" =~ ^[0-9]+$ ]] || picker=""
  else
    echo "nightly.yml at the run's head could not be read" >"$scratch/why"
  fi
fi

# The reads above may have waited out a rate limit, and a rescue may have re-run the run
# meanwhile: re-read it right before the re-run, and send the re-run with no wrapper
# retries (gh_budget_wait.sh), so a stale decision is never sent. A refused re-run fails
# this step; the next tick decides again from fresh state.
now="$(gh api "repos/$repo/actions/runs/$id" --jq '"\(.status) \(.conclusion // "-") \(.run_attempt)"')"
if [[ "$now" != "completed cancelled $attempt" ]]; then
  echo "$what changed to '$now' since it was read; not re-run"
  exit 0
fi
if [[ -n "$unserved" ]]; then
  first="$(head -n1 <<<"$unserved")"
  if [[ -n "$picker" ]]; then
    if GH_BUDGET_WAIT_ATTEMPTS=1 gh api -X POST "repos/$repo/actions/jobs/$picker/rerun" >/dev/null; then
      echo "::notice title=nightly-next tick::$what ended cancelled (attempt $attempt) with ${first%%$'\t'*} never served on ${first#*$'\t'}; re-ran pick-nightly-build-runner and every job that needs it, so the runner picker chooses fresh"
      exit 0
    fi
    # Refused: the failed jobs below. If the job re-run did start, the run is no longer
    # finished and GitHub refuses that re-run in turn.
    echo "$what: the re-run of pick-nightly-build-runner was refused; re-running the failed jobs"
  else
    echo "$what: ${first%%$'\t'*} was never served on ${first#*$'\t'}, but the picker is not re-run ($(head -n1 "$scratch/why" 2>/dev/null)); re-running the failed jobs, whose runs-on is evaluated again"
  fi
fi
GH_BUDGET_WAIT_ATTEMPTS=1 gh run rerun "$id" --failed -R "$repo"
echo "::notice title=nightly-next tick::$what ended cancelled (attempt $attempt); re-ran its failed and cancelled jobs"
