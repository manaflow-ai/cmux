#!/bin/bash
# Cancel a nightly-next build or promotion run that is stuck on a runner label that stopped serving.
#
# GitHub fixes a job's runner label when it creates the job. If that label stops serving, the job
# waits forever, and changing the runner repository variables does not move it. Run 40771197361
# (tip 1f0f687b, 2026-10-28) had `decide` waiting 34 minutes on blacksmith-4vcpu-ubuntu-2404,
# with more jobs queued behind it on the same label, while every Blacksmith Linux label had
# stopped starting jobs. A re-run creates new jobs, and those evaluate their runs-on again, so the
# way out is to cancel the run and re-run it.
#
# The rulebook allows cancelling a started nightly only when it is stuck past its timeout or
# certain to fail. A run counts as stuck here only when all of these hold:
#   - the run itself is `queued` or `in_progress`: a run that is `waiting` (an environment gate),
#     `pending` (a concurrency group) or `requested` is never cancelled, and neither is a run with
#     a pending deployment;
#   - a job has waited STUCK_MINUTES (default 20) in `queued` and no runner has taken it, on a
#     label that is not owned (glaeda-* jobs belong to the owned-pool rescue, owned_pool_rescue.py);
#   - every other job is either finished or also queued with no runner. A job that is running,
#     or `waiting` / `pending` / `requested`, keeps the run.
# A newer tip is never a reason to cancel a run.
#
# Every read is fail-closed: an unreadable tip, run list, run, deployment list or job list cancels
# nothing (the next tick decides again). The run lists are filtered to unfinished runs and read
# page by page, so newer finished runs never hide a stuck one. Right before the cancel the run, its
# deployments and its jobs are read again and must still be stuck, so a job a runner took, or a gate
# the run entered, since the first read keeps the run. (GitHub has no conditional cancel; what is
# left is the moment between that last read and the cancel.)
#
# The cancel goes out, and the run is read every SETTLE_SECONDS until it has finished. After
# FORCE_AFTER more reads it is force-cancelled, then read FORCE_AFTER more times. A run that has
# still not finished, or that can no longer be read, is left for the next tick. After the cancel:
#   - the tip's push run below MAX_ATTEMPTS (default 3, as in nightly_next_cancelled_tip.sh) is
#     re-run by the next tick step, nightly_next_cancelled_tip.sh;
#   - a dispatch of the tip on nightly-next below MAX_ATTEMPTS is re-run here through the same
#     nightly_next_rerun.sh: the build picker when a job without a runner takes its label from
#     the pick, else the failed and cancelled jobs;
#   - a run of the tip at MAX_ATTEMPTS (push or dispatch) gets a fresh run instead: nightly.yml is
#     dispatched on nightly-next, which builds the tip from attempt 1 with every runner picked
#     afresh, unless another unfinished run of the tip (in any state, gated ones included, read
#     right then) already carries it. Left queued it would never run, and cancelled with no new run
#     the tip would never build again;
#   - nothing is re-run or dispatched unless the run is seen finished `cancelled` on the attempt that
#     was judged stuck: a run that succeeded, failed or started a new attempt before the cancel took
#     is left as it is;
#   - an older commit's run is not re-run, because the tip builds;
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
here="$(dirname "$0")"

warn() { echo "::warning title=nightly-next tick::$*"; }

if ! line="$(git ls-remote origin refs/heads/nightly-next)"; then
  warn "nightly-next's tip could not be read; no run is cancelled this tick"
  exit 0
fi
tip="${line%%[[:space:]]*}"
if [[ ! "$tip" =~ ^[0-9a-f]{40}$ ]]; then
  warn "nightly-next's tip is unreadable ('${line:0:60}'); no run is cancelled this tick"
  exit 0
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
# Unfinished runs (id, event, head sha, attempt): every nightly-next run (push or dispatch), and
# main's promotion dispatches. Only `queued` and `in_progress` runs can be stuck on a label; each
# listing is read whole, page by page.
promote='select((.display_title // "") | startswith("Promote nightly-next to"))'
: >"$scratch/runs"
for status in queued in_progress; do
  if ! gh api --paginate "repos/$repo/actions/workflows/nightly.yml/runs?branch=nightly-next&status=$status&per_page=100" \
         --jq '.workflow_runs[] | "\(.id) \(.event) \(.head_sha) \(.run_attempt)"' >>"$scratch/runs" \
     || ! gh api --paginate "repos/$repo/actions/workflows/nightly.yml/runs?branch=main&event=workflow_dispatch&status=$status&per_page=100" \
         --jq ".workflow_runs[] | $promote | \"\\(.id) promote \\(.head_sha) \\(.run_attempt)\"" >>"$scratch/runs"; then
    warn "the unfinished nightly runs could not be listed; no run is cancelled this tick"
    exit 0
  fi
done
sort -u -o "$scratch/runs" "$scratch/runs"
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

# stuck ID: prints "ATTEMPT<TAB>job<TAB>labels<TAB>minutes" when the run is stuck, nothing when it
# is not; fails when any read fails (the caller then leaves the run alone).
stuck() {
  local state deployments
  state="$(gh api "repos/$repo/actions/runs/$1" --jq '"\(.status) \(.run_attempt)"')" || return 1
  case "${state% *}" in queued | in_progress) ;; *) return 0 ;; esac
  deployments="$(gh api "repos/$repo/actions/runs/$1/pending_deployments" --jq length)" || return 1
  [[ "$deployments" == 0 ]] || return 0
  gh api --paginate "repos/$repo/actions/runs/$1/jobs?filter=latest&per_page=100" --jq '.jobs[]' >"$scratch/jobs" || return 1
  local job
  job="$(jq -rs --argjson now "$(date -u +%s)" --argjson minutes "$stuck_minutes" "$stuck_filter" "$scratch/jobs")" || return 1
  [[ -z "$job" ]] || printf '%s\t%s\n' "${state#* }" "$job"
}

# settled ID ATTEMPT: 0 when the run has finished cancelled on ATTEMPT, 1 when it has not finished,
# 2 when it cannot be read, 3 when it finished some other way (it succeeded or failed before the
# cancel reached it, or a new attempt started): then nothing is re-run or dispatched for it.
settled() {
  local now
  now="$(gh api "repos/$repo/actions/runs/$1" --jq '"\(.status) \(.conclusion // "-") \(.run_attempt)"')" || return 2
  case "$now" in
    "completed cancelled $2") return 0 ;;
    "completed "*) return 3 ;;
    *" $2") return 1 ;;
    *) return 3 ;;
  esac
}
# wait_settled ID ATTEMPT: settled's answer after up to FORCE_AFTER + 1 reads, SETTLE_SECONDS apart.
wait_settled() {
  local i rc
  for ((i = 0; i <= force_after; i++)); do
    (( i == 0 )) || sleep "$settle_seconds"
    rc=0
    settled "$1" "$2" || rc=$?
    (( rc == 1 )) || return "$rc"
  done
  return 1
}

# carrier: prints the id of a nightly-next run of the tip other than the cancelled ones that has not
# finished, whatever its state (queued, in_progress, waiting, pending, requested), or nothing; fails
# when the list cannot be read. Read when it is needed, so a run started since the listing counts.
carrier() {
  local oid osha
  gh api --paginate "repos/$repo/actions/workflows/nightly.yml/runs?branch=nightly-next&head_sha=$tip&per_page=100" \
    --jq '.workflow_runs[] | select(.status != "completed") | "\(.id) \(.head_sha)"' >"$scratch/carriers" || return 1
  while read -r oid osha; do
    [[ "$osha" == "$tip" && "$cancelled" != *" $oid "* ]] && { echo "$oid"; return 0; }
  done <"$scratch/carriers"
  return 0
}

cancelled=" "
while read -r id event sha attempt; do
  if ! found="$(stuck "$id")"; then
    echo "nightly-next run $id: could not be read; left alone"
    continue
  fi
  if [[ -z "$found" ]]; then
    echo "nightly-next run $id ($event, ${sha:0:12}): running or waiting, no job stuck without a runner"
    continue
  fi
  IFS=$'\t' read -r attempt job labels waited <<<"$found"
  why="$job has waited $waited min with no runner on $labels"
  tip_run=""
  [[ "$sha" == "$tip" && ("$event" == push || "$event" == workflow_dispatch) ]] && tip_run=1
  # The last read before the cancel: the run must still be stuck on the same attempt.
  if ! again="$(stuck "$id")" || [[ -z "$again" || "${again%%$'\t'*}" != "$attempt" ]]; then
    echo "nightly-next run $id: changed since it was read (a runner, a gate or a new attempt); left alone"
    continue
  fi
  gh api -X POST "repos/$repo/actions/runs/$id/cancel" >/dev/null || true
  rc=0
  wait_settled "$id" "$attempt" || rc=$?
  if (( rc == 1 )); then
    gh api -X POST "repos/$repo/actions/runs/$id/force-cancel" >/dev/null || true
    rc=0
    wait_settled "$id" "$attempt" || rc=$?
  fi
  if (( rc == 3 )); then
    echo "nightly-next run $id: finished on its own or moved to a new attempt before the cancel took; nothing is re-run or dispatched"
    continue
  fi
  if (( rc != 0 )); then
    warn "run $id is stuck ($why); the cancel was sent but the run has not been seen finished cancelled, so nothing is re-run; the next tick checks again"
    continue
  fi
  cancelled+="$id "
  echo "::notice title=nightly-next tick::cancelled run $id ($event, ${sha:0:12}, attempt $attempt): $why"
  if [[ -n "$tip_run" ]] && (( attempt >= max_attempts )); then
    # Out of attempts: a fresh run of the tip, unless another unfinished run carries it (in any
    # state, a gated one included), read now.
    if ! other="$(carrier)"; then
      warn "run $id was on attempt $attempt of $max_attempts; the tip's other runs could not be read, so no fresh run is dispatched; the next tick checks again"
    elif [[ -n "$other" ]]; then
      echo "nightly-next run $id: out of attempts; run $other still carries the tip, so no fresh run is dispatched"
    elif GH_BUDGET_WAIT_ATTEMPTS=1 gh workflow run nightly.yml -R "$repo" --ref nightly-next </dev/null; then
      echo "::notice title=nightly-next tick::run $id was on attempt $attempt of $max_attempts; dispatched a fresh nightly.yml run of the tip ${tip:0:12} on nightly-next, with every runner picked afresh"
    else
      warn "run $id was on attempt $attempt of $max_attempts and the fresh dispatch of the tip ${tip:0:12} was refused; the feed watch dispatches the tick again"
    fi
  elif [[ "$event" == push && -n "$tip_run" ]]; then
    echo "nightly-next run $id: the tip's run; the next step re-runs it so its runners are picked fresh"
  elif [[ "$event" == workflow_dispatch && -n "$tip_run" ]] && (( attempt < max_attempts )); then
    bash "$here/nightly_next_rerun.sh" "$repo" "$id" "$attempt" "$sha" "nightly-next dispatch $id" </dev/null \
      || warn "the re-run of run $id was refused"
  else
    echo "nightly-next run $id: not re-run (an older commit's, or a promotion the request below asks for again)"
  fi
done <"$scratch/runs"
