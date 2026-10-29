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
# nothing (the next tick decides again), and so does one of an unexpected shape (a run status that is
# not a word and a number, deployments that are not a list, a job without a status, labels or a
# creation time). The run lists are filtered to unfinished runs and read
# page by page, so newer finished runs never hide a stuck one. Right before the cancel the run, its
# deployments and its jobs are read again and must still be stuck, so a job a runner took, or a gate
# the run entered, since the first read keeps the run. (GitHub has no conditional cancel; what is
# left is the moment between that last read and the cancel.)
#
# The cancel goes out with no wrapper retries (GH_BUDGET_WAIT_ATTEMPTS=1), so it never lands long
# after the last read on a run that has moved on; a refused cancel leaves the run for the next tick.
# The run is then read every SETTLE_SECONDS until it has finished. After FORCE_AFTER more reads, and
# only when the last of them still shows the same attempt unfinished, it is force-cancelled (no
# retries either), then read FORCE_AFTER more times. A run that has still not finished, or that can
# no longer be read, is left for the next tick. Nothing more is done unless the run is seen finished
# `cancelled` on the attempt judged stuck: a run that succeeded, failed or started a new attempt
# before the cancel took is left as it is. After the cancel:
#   - a run of the tip (push or dispatch) is built again by the next tick step,
#     nightly_next_cancelled_tip.sh: GitHub's record of the tip's newest run ended `cancelled` is
#     the obligation it reads every tick, and it re-runs that run below MAX_ATTEMPTS (default 3) or
#     dispatches a fresh run at the cap, until a replacement exists. A refused re-run or dispatch,
#     or a tick that dies after the cancel, leaves that record, so no cancelled tip is stranded;
#   - an older commit's run is not re-run, because the tip builds;
#   - a promotion (nightly.yml on main, "Promote nightly-next to ...") is not re-run, because the
#     tick's promotion request, a later step of the same job, asks again.
#
#   nightly_next_stuck_run.sh REPO
# Needs gh (GH_TOKEN with actions: write), jq, and git with an `origin` for REPO.
set -euo pipefail

repo="${1:?usage: nightly_next_stuck_run.sh OWNER/REPO}"
stuck_minutes="${STUCK_MINUTES:-20}"
max_attempts="${MAX_ATTEMPTS:-3}"  # only named in messages: nightly_next_cancelled_tip.sh applies it
settle_seconds="${SETTLE_SECONDS:-15}"
force_after="${FORCE_AFTER:-6}"

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
# A run's line, built only from fields of the right JSON type: jq would render a null as the word
# "null", which a pattern on the text cannot tell from a real value. Any other shape is a jq error,
# which fails the listing and cancels nothing.
typed_run='if (.id | type) == "number" and (.event | type) == "string" and (.head_sha | type) == "string" and (.run_attempt | type) == "number" and (.status | type) == "string" then . else error("a run of an unexpected shape") end'
: >"$scratch/runs"
for status in queued in_progress; do
  if ! gh api --paginate "repos/$repo/actions/workflows/nightly.yml/runs?branch=nightly-next&status=$status&per_page=100" \
         --jq ".workflow_runs[] | $typed_run | \"\\(.id) \\(.event) \\(.head_sha) \\(.run_attempt)\"" >>"$scratch/runs" \
     || ! gh api --paginate "repos/$repo/actions/workflows/nightly.yml/runs?branch=main&event=workflow_dispatch&status=$status&per_page=100" \
         --jq ".workflow_runs[] | $typed_run | $promote | \"\\(.id) promote \\(.head_sha) \\(.run_attempt)\"" >>"$scratch/runs"; then
    warn "the unfinished nightly runs could not be listed; no run is cancelled this tick"
    exit 0
  fi
done
sort -u -o "$scratch/runs" "$scratch/runs"
# Every line must be "id event sha attempt"; any other shape is an unread listing.
if grep -Evq '^[0-9]+ [a-z_]+ [0-9a-f]{40} [0-9]+$' "$scratch/runs"; then
  warn "the unfinished nightly runs came back in an unexpected shape; no run is cancelled this tick"
  exit 0
fi
if [[ ! -s "$scratch/runs" ]]; then
  echo "nightly-next: no unfinished nightly or promotion run"
  exit 0
fi

# The first stuck job of a run's latest attempt (name<TAB>labels<TAB>minutes), or nothing. Fail-closed
# on shape: a job without a string status, a labels array of strings (non-empty on a queued job, which
# is judged by it) or a created_at timestamp makes
# jq fail (error), and the caller then leaves the run alone; a job is never judged on a field it lacks.
stuck_filter='
  def checked: if (type == "object") and (.status | type) == "string"
                   and ((.labels | type) == "array") and all(.labels[]; type == "string")
                   and (.status != "queued" or (.labels | length) > 0)
                   and ((.created_at | type) == "string")
               then . else error("a job of an unexpected shape") end;
  def unserved: .status == "queued" and ((.runner_name // "") == "");
  [.[] | checked] as $jobs
  | if ($jobs | length) == 0 then error("no jobs") else . end
  | [$jobs[] | select(unserved and (.labels | any(startswith("glaeda-")) | not))
     | . + {waited: (($now - (.created_at | fromdateiso8601)) / 60 | floor)}
     | select(.waited >= $minutes)] as $stuck
  | if ($stuck | length) > 0 and all($jobs[]; .status == "completed" or unserved)
    then $stuck[0] | "\(.name)\t\(.labels | join(","))\t\(.waited)" else empty end'

# stuck ID: prints "ATTEMPT<TAB>job<TAB>labels<TAB>minutes" when the run is stuck, nothing when it
# is not; fails when any read fails (the caller then leaves the run alone).
stuck() {
  local state deployments
  state="$(gh api "repos/$repo/actions/runs/$1" --jq "$typed_run | \"\\(.status) \\(.run_attempt)\"")" || return 1
  [[ "$state" =~ ^[a-z_]+\ [0-9]+$ ]] || return 1
  case "${state% *}" in queued | in_progress) ;; *) return 0 ;; esac
  # Pending deployments must come back as an array: null, an object or anything else is unread.
  deployments="$(gh api "repos/$repo/actions/runs/$1/pending_deployments" \
    --jq 'if type == "array" then length else error("not a list") end')" || return 1
  [[ "$deployments" =~ ^[0-9]+$ ]] || return 1
  [[ "$deployments" == 0 ]] || return 0
  gh api --paginate "repos/$repo/actions/runs/$1/jobs?filter=latest&per_page=100" --jq '.jobs[]' >"$scratch/jobs" || return 1
  local job
  job="$(jq -rs --argjson now "$(date -u +%s)" --argjson minutes "$stuck_minutes" "$stuck_filter" "$scratch/jobs")" || return 1
  [[ -z "$job" ]] || printf '%s\t%s\n' "${state#* }" "$job"
}

# A run's "status conclusion attempt", or a jq error when a field has an unexpected type.
settle_filter='if (.status | type) == "string" and (.run_attempt | type) == "number" and ((.conclusion | type) == "string" or .conclusion == null) then "\(.status) \(.conclusion // "-") \(.run_attempt)" else error("a run of an unexpected shape") end'

# settled ID ATTEMPT: 0 when the run has finished cancelled on ATTEMPT, 1 when it has not finished,
# 2 when it cannot be read, 3 when it finished some other way (it succeeded or failed before the
# cancel reached it, or a new attempt started): then nothing is re-run or dispatched for it.
settled() {
  local now
  now="$(gh api "repos/$repo/actions/runs/$1" --jq "$settle_filter")" || return 2
  [[ "$now" =~ ^[a-z_]+\ [a-z_-]+\ [0-9]+$ ]] || return 2
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
  # The writes go out with no wrapper retries (gh_budget_wait.sh): a cancel that waited out a rate
  # limit could land long after the read above, on a run that has moved on. A refused write leaves
  # the run for the next tick, which reads it afresh.
  if ! GH_BUDGET_WAIT_ATTEMPTS=1 gh api -X POST "repos/$repo/actions/runs/$id/cancel" >/dev/null; then
    warn "run $id is stuck ($why), but the cancel was refused; the next tick reads it again"
    continue
  fi
  rc=0
  wait_settled "$id" "$attempt" || rc=$?
  if (( rc == 1 )); then
    # wait_settled's last read just said: same attempt, not finished. Only then force-cancel.
    if ! GH_BUDGET_WAIT_ATTEMPTS=1 gh api -X POST "repos/$repo/actions/runs/$id/force-cancel" >/dev/null; then
      warn "run $id did not finish after its cancel and the force-cancel was refused; the next tick reads it again"
      continue
    fi
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
  echo "::notice title=nightly-next tick::cancelled run $id ($event, ${sha:0:12}, attempt $attempt): $why"
  if [[ -n "$tip_run" ]]; then
    echo "nightly-next run $id: the tip's run; the next step (nightly_next_cancelled_tip.sh) builds the tip again, by a re-run or, at attempt $max_attempts, a fresh run"
  else
    echo "nightly-next run $id: not re-run (an older commit's, or a promotion the request below asks for again)"
  fi
done <"$scratch/runs"
