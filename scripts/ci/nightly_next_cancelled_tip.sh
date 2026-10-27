#!/bin/bash
# Re-run the nightly-next tip's nightly when its newest run ended cancelled.
#
# The tick requests a promotion only for a commit that is not on nightly-next yet,
# so a tip whose run was cancelled was never built again: the owned-pool rescue
# cancelled run 40340830337 (e22f9384) at 2026-10-26 14:36Z to move a queued job,
# lost the re-run to a rate limit, and the tick then logged "already on
# nightly-next" every half hour. A nightly is never cancelled on purpose once
# started (a newer tip builds alongside it), so a cancelled tip run is one to
# finish: its failed and cancelled jobs are re-run, at most MAX_ATTEMPTS attempts
# in all.
#
# A re-run of failed jobs keeps pick-nightly-build-runner's outputs from the
# earlier attempt, so its jobs take that pick's Blacksmith label (nightly.yml takes
# the owned pick only when it was made for the run's own attempt). That is right
# after a refusal, and wrong when the earlier attempt's label was in outage: a job
# of the cancelled attempt that ended cancelled or failed with no runner ever
# assigned, on a picked macOS label (glaeda-* or blacksmith-*-macos-*), never got a
# machine there. Then pick-nightly-build-runner is re-run instead (GitHub re-runs a
# job and every job that needs it), so the picker chooses fresh (an idle owned Mac,
# else a moving Blacksmith label) rather than queueing on the same dead label. That
# is done only when scripts/ci/nightly_repick.py (owned_pool_rescue.repick_job(), the
# rescue's own rule) finds it safe: every failed job needs the picker, and a finished
# job it would build again uploads only with `overwrite: true`. A whole re-run is never
# sent: it would repeat jobs whose fixed-name uploads then fail. Otherwise, or if a
# read fails, the failed jobs are re-run as before.
#
#   nightly_next_cancelled_tip.sh REPO
# Needs gh (GH_TOKEN with actions: write) and git with an `origin` for REPO.
set -euo pipefail

repo="${1:?usage: nightly_next_cancelled_tip.sh OWNER/REPO}"
max_attempts="${MAX_ATTEMPTS:-3}"

line="$(git ls-remote origin refs/heads/nightly-next)"
tip="${line%%[[:space:]]*}"
[[ "$tip" =~ ^[0-9a-f]{40}$ ]] || { echo "nightly-next tip: unreadable; nothing to check"; exit 0; }

# The tip's push runs of nightly.yml, newest first: id, status, conclusion, attempt.
runs="$(gh api "repos/$repo/actions/workflows/nightly.yml/runs?branch=nightly-next&event=push&head_sha=$tip&per_page=10" \
  --jq '.workflow_runs | sort_by(.id) | reverse | .[] | "\(.id) \(.status) \(.conclusion // "-") \(.run_attempt)"')"
if [[ -z "$runs" ]]; then
  echo "nightly-next tip ${tip:0:12}: no nightly run yet"
  exit 0
fi
if grep -qv ' completed ' <<<"$runs"; then
  echo "nightly-next tip ${tip:0:12}: a nightly run is building"
  exit 0
fi
read -r id _ conclusion attempt <<<"$(head -n1 <<<"$runs")"
if [[ "$conclusion" != cancelled ]]; then
  echo "nightly-next tip ${tip:0:12}: newest run $id ended $conclusion"
  exit 0
fi
if (( attempt >= max_attempts )); then
  echo "::warning title=nightly-next tick::the tip ${tip:0:12}'s run $id was cancelled on attempt $attempt of $max_attempts; not re-run again"
  exit 0
fi

# Jobs of that attempt that ended with no runner on a picked macOS label: name<TAB>labels.
unserved_filter='select((.conclusion == "cancelled" or .conclusion == "failure") and ((.runner_name // "") == "")) | select(any(.labels[]; test("^(glaeda-|blacksmith-[0-9]+vcpu-macos-)"))) | "\(.name)\t\(.labels | join(","))"'
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
unserved=""
if gh api --paginate "repos/$repo/actions/runs/$id/attempts/$attempt/jobs?per_page=100" --jq '.jobs[]' >"$scratch/jobs"; then
  unserved="$(jq -r "$unserved_filter" "$scratch/jobs")" || unserved=""
else
  echo "nightly-next tip ${tip:0:12}: could not read attempt $attempt's jobs; re-running its failed jobs"
fi
# The picker job to re-run, when nightly.yml at the tip says that is safe.
picker=""
if [[ -n "$unserved" ]]; then
  if gh api "repos/$repo/contents/.github/workflows/nightly.yml?ref=$tip" --jq .content | base64 -d >"$scratch/nightly.yml"; then
    picker="$(python3 "$(dirname "$0")/nightly_repick.py" "$scratch/nightly.yml" "$scratch/jobs" 2>"$scratch/why")" || picker=""
    [[ "$picker" =~ ^[0-9]+$ ]] || picker=""
  else
    echo "nightly.yml at the tip could not be read" >"$scratch/why"
  fi
fi

# The reads above may have waited out a rate limit, and a rescue may have re-run the run
# meanwhile: re-read it right before the re-run, and send the re-run with no wrapper
# retries (gh_budget_wait.sh), so a stale decision is never sent. A refused re-run fails
# this step; the next tick decides again from fresh state.
now="$(gh api "repos/$repo/actions/runs/$id" --jq '"\(.status) \(.conclusion // "-") \(.run_attempt)"')"
if [[ "$now" != "completed cancelled $attempt" ]]; then
  echo "nightly-next tip ${tip:0:12}: run $id changed to '$now' since it was read; not re-run"
  exit 0
fi
if [[ -n "$unserved" ]]; then
  first="$(head -n1 <<<"$unserved")"
  if [[ -n "$picker" ]]; then
    if GH_BUDGET_WAIT_ATTEMPTS=1 gh api -X POST "repos/$repo/actions/jobs/$picker/rerun" >/dev/null; then
      echo "::notice title=nightly-next tick::the tip ${tip:0:12}'s run $id ended cancelled (attempt $attempt) with ${first%%$'\t'*} never served on ${first#*$'\t'}; re-ran pick-nightly-build-runner and every job that needs it, so the runner picker chooses fresh"
      exit 0
    fi
    # Refused: the failed jobs below. If the job re-run did start, the run is no longer
    # finished and GitHub refuses that re-run in turn.
    echo "nightly-next tip ${tip:0:12}: the re-run of pick-nightly-build-runner was refused; re-running the failed jobs"
  else
    echo "nightly-next tip ${tip:0:12}: ${first%%$'\t'*} was never served on ${first#*$'\t'}, but the picker is not re-run ($(head -n1 "$scratch/why" 2>/dev/null)); re-running the failed jobs"
  fi
fi
GH_BUDGET_WAIT_ATTEMPTS=1 gh run rerun "$id" --failed -R "$repo"
echo "::notice title=nightly-next tick::the tip ${tip:0:12}'s run $id ended cancelled (attempt $attempt); re-ran its failed and cancelled jobs"
