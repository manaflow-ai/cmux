#!/bin/bash
# Re-run a finished, cancelled nightly.yml attempt so its runners are picked fresh.
#
#   nightly_next_rerun.sh REPO RUN_ID ATTEMPT HEAD_SHA WHAT
# WHAT names the run in messages ("the tip 1f0f687b2f32's run 40771197361").
# Callers: nightly_next_cancelled_tip.sh (the tip's push run) and nightly_next_stuck_run.sh (a
# dispatch on nightly-next it cancelled). Needs gh (GH_TOKEN with actions: write) and python3.
#
# Nothing is re-run unless every read succeeds with the shape it expects, and, right before the
# write, nightly_next_tip_owed.sh finds the tip still owed (see it).
#
# A re-run of failed jobs keeps the runner picker's outputs from the earlier attempt, so
# the jobs that take their runner from that pick take its Blacksmith label again (nightly.yml takes
# the owned pick only when it was made for the run's own attempt). That is right after a refusal,
# and wrong when the earlier attempt's label was in outage. So the attempt's jobs that ended
# cancelled or failed with no runner ever assigned (on any label: macOS, Linux or owned) are read,
# and when one of them takes its runner from a picker job's outputs, that picker is re-run instead
# (GitHub re-runs a job and every job that needs it), so the picker chooses fresh. The picker is read
# from nightly.yml at the run's head (the job whose outputs those jobs' runs-on read), never a fixed
# name. That is done only
# when scripts/ci/nightly_repick.py (owned_pool_rescue.repick_job(), the rescue's own rule) finds it
# safe: every failed job needs the picker, and a finished job it would build again uploads only with
# `overwrite: true`. A whole re-run is never sent: it would repeat jobs whose fixed-name uploads then
# fail. Otherwise the failed jobs are re-run (a read that fails sends nothing): GitHub creates them again, and
# each evaluates its runs-on against the current runner variables. A job whose runs-on is a literal
# label goes back to that label; moving it is the runner set's failover, not this script's.
set -euo pipefail

repo="${1:?usage: nightly_next_rerun.sh REPO RUN_ID ATTEMPT HEAD_SHA WHAT}"
id="${2:?}"
attempt="${3:?}"
head_sha="${4:?}"
what="${5:-run $id}"

# Every Actions object is read through scripts/ci/nightly_next_shapes.jq (typed_run, typed_job,
# page_of): gh fetches the raw JSON and jq checks each field's type before anything reads it.
shapes_dir="$(cd "$(dirname "$0")" && pwd)"
shape() { jq -L "$shapes_dir" -rc "include \"nightly_next_shapes\"; $1"; }
# Jobs of that attempt that ended with no runner: name<TAB>labels. Every read below is fail-closed:
# a read that fails or comes back in an unexpected shape (typed_job) sends no write at all (not even
# the re-run of failed jobs), and the tip stays owed, so the next tick tries again.
unserved_filter='select((.conclusion == "cancelled" or .conclusion == "failure") and ((.runner_name // "") == "")) | "\(.name)\t\(.labels | join(","))"'
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
held() { echo "$what: $*; nothing re-run this tick, the next tick tries again"; exit 0; }
gh api --paginate "repos/$repo/actions/runs/$id/attempts/$attempt/jobs?per_page=100" | shape 'page_of("jobs") | typed_job' >"$scratch/jobs" \
  || held "attempt $attempt's jobs could not be read"
[[ -s "$scratch/jobs" ]] || held "attempt $attempt has no jobs to read"
unserved="$(jq -r "$unserved_filter" "$scratch/jobs")" || held "attempt $attempt's jobs could not be parsed"
# The picker job to re-run, when nightly.yml at the run's head says that is useful and safe.
# nightly_repick.py answers a job id, or nothing with why (a decision: the failed jobs are re-run);
# an unreadable workflow or a failing script is no decision, and sends nothing.
picker=""
if [[ -n "$unserved" ]]; then
  cut -f1 <<<"$unserved" >"$scratch/unserved"
  gh api "repos/$repo/contents/.github/workflows/nightly.yml?ref=$head_sha" \
    --jq 'if (.content | type) == "string" then .content else error("no content") end' >"$scratch/nightly.b64" \
    || held "nightly.yml at ${head_sha:0:12} could not be read"
  base64 -d "$scratch/nightly.b64" >"$scratch/nightly.yml" 2>/dev/null && [[ -s "$scratch/nightly.yml" ]] \
    || held "nightly.yml at ${head_sha:0:12} could not be decoded"
  picker="$(python3 "$(dirname "$0")/nightly_repick.py" "$scratch/nightly.yml" "$scratch/jobs" "$scratch/unserved" 2>"$scratch/why")" \
    || held "the picker check failed ($(head -n1 "$scratch/why" 2>/dev/null))"
  [[ -z "$picker" || "$picker" =~ ^[0-9]+$ ]] || held "the picker check answered '$picker'"
fi

# The last read before the write (nightly_next_tip_owed.sh): nightly-next still points at the run's
# head, no other run of it is unfinished in any state, and the run is still its newest, finished
# cancelled on the attempt read. The reads above may have waited out a rate limit, and meanwhile
# a rescue, another tick or a person may have moved things. The re-run goes out with no wrapper
# retries (gh_budget_wait.sh), so a stale decision is never sent. A refused re-run fails this
# step; the next tick decides again from fresh state.
rc=0
why="$(bash "$(dirname "$0")/nightly_next_tip_owed.sh" "$repo" "$head_sha" "$id" "$attempt")" || rc=$?
if (( rc == 1 )); then
  echo "$what: $why; not re-run"
  exit 0
elif (( rc != 0 )); then
  held "$why"
fi
if [[ -n "$unserved" ]]; then
  first="$(head -n1 <<<"$unserved")"
  if [[ -n "$picker" ]]; then
    if GH_BUDGET_WAIT_ATTEMPTS=1 gh api -X POST "repos/$repo/actions/jobs/$picker/rerun" >/dev/null; then
      echo "::notice title=nightly-next tick::$what ended cancelled (attempt $attempt) with ${first%%$'\t'*} never served on ${first#*$'\t'}; re-ran its runner picker (job $picker) and every job that needs it, so the picker chooses fresh"
      exit 0
    fi
    # Refused: the failed jobs below. If the job re-run did start, the run is no longer
    # finished and GitHub refuses that re-run in turn.
    echo "$what: the re-run of its runner picker (job $picker) was refused; re-running the failed jobs"
  else
    echo "$what: ${first%%$'\t'*} was never served on ${first#*$'\t'}, but the picker is not re-run ($(head -n1 "$scratch/why" 2>/dev/null)); re-running the failed jobs, whose runs-on is evaluated again"
  fi
fi
GH_BUDGET_WAIT_ATTEMPTS=1 gh run rerun "$id" --failed -R "$repo"
echo "::notice title=nightly-next tick::$what ended cancelled (attempt $attempt); re-ran its failed and cancelled jobs"
