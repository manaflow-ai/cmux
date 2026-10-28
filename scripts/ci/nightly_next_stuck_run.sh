#!/bin/bash
# Cancel a nightly-next build or promotion run that is stuck on a runner label that stopped serving.
#
# GitHub fixes a job's runner label when it creates the job. If that label stops serving, the job
# waits forever, and changing the runner repository variables does not move it. Run 40771197361
# (tip 1f0f687b, 2026-10-28) had `decide` waiting 34 minutes on blacksmith-4vcpu-ubuntu-2404,
# with more jobs queued behind it on the same label, while every Blacksmith Linux label had
# stopped starting jobs. A re-run creates new jobs, and those evaluate their runs-on against the
# current variables, so the way out is to cancel the run and re-run it.
#
# The rulebook allows cancelling a started nightly only when it is stuck past its timeout or
# certain to fail. A run counts as stuck here only when all of these hold:
#   - a job has waited STUCK_MINUTES (default 20) in `queued` and no runner has taken it;
#   - every other job is either finished or also queued with no runner. A job that is running,
#     or waiting on an environment gate or a concurrency group, keeps the run, so a run that is
#     only running or only waiting on a gate is never cancelled;
#   - the stuck job is not on an owned label (glaeda-*). Those belong to the owned-pool rescue
#     (owned_pool_rescue.py), which moves such jobs on a timed hold;
#   - a run the tick re-runs (the tip's push run, a dispatch) is below MAX_ATTEMPTS (default 3,
#     as in nightly_next_cancelled_tip.sh), so a cancel is always followed by a re-run.
# A newer tip is never a reason to cancel a run.
#
# The cancel goes out, and the run is read every SETTLE_SECONDS until it has finished. After
# FORCE_AFTER reads it is force-cancelled, then read FORCE_AFTER more times. A run that has still
# not finished is left for the next tick. After the cancel:
#   - the tip's push run is re-run by the next tick step, nightly_next_cancelled_tip.sh, the
#     #26322 path: a re-run of the build picker when a picked macOS label never served a job,
#     else a re-run of the failed and cancelled jobs. Both take the current runner variables;
#   - a dispatch on nightly-next gets its failed and cancelled jobs re-run;
#   - an older commit's push run is not re-run, because the tip builds;
#   - a promotion (nightly.yml on main, "Promote nightly-next to ...") is not re-run, because the
#     tick's promotion request, a later step of the same job, asks again.
#
#   nightly_next_stuck_run.sh REPO
# Needs gh (GH_TOKEN with actions: write), jq, and git with an `origin` for REPO.
set -euo pipefail

repo="${1:?usage: nightly_next_stuck_run.sh OWNER/REPO}"
stuck_minutes="${STUCK_MINUTES:-20}"
max_attempts="${MAX_ATTEMPTS:-3}"
settle_seconds="${SETTLE_SECONDS:-15}"
force_after="${FORCE_AFTER:-6}"

line="$(git ls-remote origin refs/heads/nightly-next || true)"
tip="${line%%[[:space:]]*}"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
# Unfinished runs: id, event, head sha, attempt. Every nightly-next run (push or dispatch), and
# main's promotion dispatches.
gh api "repos/$repo/actions/workflows/nightly.yml/runs?branch=nightly-next&per_page=30" \
  --jq '.workflow_runs[] | select(.status != "completed") | "\(.id) \(.event) \(.head_sha) \(.run_attempt)"' >"$scratch/runs"
gh api "repos/$repo/actions/workflows/nightly.yml/runs?branch=main&event=workflow_dispatch&per_page=30" \
  --jq '.workflow_runs[] | select(.status != "completed") | select((.display_title // "") | startswith("Promote nightly-next to")) | "\(.id) promote \(.head_sha) \(.run_attempt)"' >>"$scratch/runs"
if [[ ! -s "$scratch/runs" ]]; then
  echo "nightly-next: no unfinished nightly or promotion run"
  exit 0
fi

# The first stuck job of a run's latest attempt (name<TAB>labels<TAB>minutes), or nothing.
stuck_filter='
  def unserved: .status == "queued" and ((.runner_name // "") == "");
  . as $jobs
  | [$jobs[] | select(unserved and ((.labels // []) | any(startswith("glaeda-")) | not))
     | . + {waited: (($now - (.created_at | fromdateiso8601)) / 60 | floor)}
     | select(.waited >= $minutes)] as $stuck
  | if ($stuck | length) > 0 and all($jobs[]; .status == "completed" or unserved)
    then $stuck[0] | "\(.name)\t\((.labels // []) | join(","))\t\(.waited)" else empty end'

settled() { [[ "$(gh api "repos/$repo/actions/runs/$1" --jq .status)" == completed ]]; }
wait_settled() {
  local i
  for ((i = 0; i < force_after; i++)); do
    settled "$1" && return 0
    sleep "$settle_seconds"
  done
  settled "$1"
}

while read -r id event sha attempt; do
  if ! gh api --paginate "repos/$repo/actions/runs/$id/jobs?filter=latest&per_page=100" --jq '.jobs[]' >"$scratch/jobs"; then
    echo "nightly-next run $id: could not read its jobs; left alone"
    continue
  fi
  stuck="$(jq -rs --argjson now "$(date -u +%s)" --argjson minutes "$stuck_minutes" "$stuck_filter" "$scratch/jobs")" || stuck=""
  if [[ -z "$stuck" ]]; then
    echo "nightly-next run $id ($event, ${sha:0:12}): running or waiting, no job stuck without a runner"
    continue
  fi
  IFS=$'\t' read -r job labels waited <<<"$stuck"
  why="$job has waited $waited min with no runner on $labels"
  # A run the tick would re-run, but has re-run MAX_ATTEMPTS times, stays queued: cancelled, it
  # would never run, and queued, it still runs if its label comes back.
  if [[ ("$event" == push && "$sha" == "$tip") || "$event" == workflow_dispatch ]] && (( attempt >= max_attempts )); then
    echo "::warning title=nightly-next tick::run $id is stuck ($why) on attempt $attempt of $max_attempts; left queued"
    continue
  fi
  gh api -X POST "repos/$repo/actions/runs/$id/cancel" >/dev/null || true
  if ! wait_settled "$id"; then
    gh api -X POST "repos/$repo/actions/runs/$id/force-cancel" >/dev/null || true
    if ! wait_settled "$id"; then
      echo "::warning title=nightly-next tick::run $id is stuck ($why); cancel and force-cancel sent, it has not finished yet, the next tick checks again"
      continue
    fi
  fi
  echo "::notice title=nightly-next tick::cancelled run $id ($event, ${sha:0:12}): $why"
  if [[ "$event" == push && "$sha" == "$tip" ]]; then
    echo "nightly-next run $id: the tip's run; the next step re-runs it so its runners are picked fresh"
  elif [[ "$event" == workflow_dispatch ]]; then
    if GH_BUDGET_WAIT_ATTEMPTS=1 gh run rerun "$id" --failed -R "$repo"; then
      echo "::notice title=nightly-next tick::re-ran run $id's failed and cancelled jobs, so their runners are picked fresh"
    else
      echo "::warning title=nightly-next tick::the re-run of run $id was refused"
    fi
  else
    echo "nightly-next run $id: not re-run (an older commit's, or a promotion the request below asks for again)"
  fi
done <"$scratch/runs"
