#!/bin/bash
# Build the nightly-next tip again when its newest nightly run ended cancelled.
#
# The tick requests a promotion only for a commit that is not on nightly-next yet,
# so a tip whose run was cancelled was never built again: the owned-pool rescue
# cancelled run 40340830337 (e22f9384) at 2026-10-26 14:36Z to move a queued job,
# lost the re-run to a rate limit, and the tick then logged "already on
# nightly-next" every half hour. A nightly is never cancelled on purpose once
# started (a newer tip builds alongside it), so a cancelled tip run is one to
# finish.
#
# The obligation is GitHub's own record, read every tick: the tip's newest nightly.yml run (push
# or dispatch) on nightly-next ended `cancelled`. GitHub writes it with the cancel itself, so no
# cancel can happen without it, and it is cleared only by a newer run of the tip (a re-run's new
# attempt or a fresh run), whatever happened to the tick that cancelled. Each tick:
#   - a run of the tip that has not finished (queued, in progress, waiting, pending, requested)
#     carries the tip: nothing is done;
#   - below MAX_ATTEMPTS the cancelled run is re-run by scripts/ci/nightly_next_rerun.sh (its
#     runner picker when a job left without a runner takes its label from the pick and that is
#     safe, else the failed jobs);
#   - at MAX_ATTEMPTS a fresh nightly.yml run is dispatched on nightly-next (attempt 1, every
#     runner picked afresh). A refused dispatch, or a tick that never got that far, leaves the
#     record as it was, so the next tick dispatches again: at most one per tick, until a
#     replacement exists.
# Every write goes out with no wrapper retries (GH_BUDGET_WAIT_ATTEMPTS=1) right after a fresh
# read of the run and of nightly-next itself (it must still point at the tip that was read), so a stale decision is never sent; a refused write fails this step and the
# next tick decides again.
#
#   nightly_next_cancelled_tip.sh REPO
# Needs gh (GH_TOKEN with actions: write) and git with an `origin` for REPO.
set -euo pipefail

repo="${1:?usage: nightly_next_cancelled_tip.sh OWNER/REPO}"
max_attempts="${MAX_ATTEMPTS:-3}"

line="$(git ls-remote origin refs/heads/nightly-next)"
tip="${line%%[[:space:]]*}"
[[ "$tip" =~ ^[0-9a-f]{40}$ ]] || { echo "nightly-next tip: unreadable; nothing to check"; exit 0; }

# The tip's nightly.yml runs on nightly-next (push or dispatch), newest first: id, status,
# conclusion, attempt.
tip_runs() {
  gh api --paginate "repos/$repo/actions/workflows/nightly.yml/runs?branch=nightly-next&head_sha=$tip&per_page=100" \
    --jq '.workflow_runs[] | select(.event == "push" or .event == "workflow_dispatch") | "\(.id) \(.status) \(.conclusion // "-") \(.run_attempt)"' \
    | sort -rn
}
runs="$(tip_runs)"
# Every line must be "id status conclusion attempt"; a run of any other shape is unread, and nothing
# is sent this tick.
if [[ -n "$runs" ]] && grep -Evq '^[0-9]+ [a-z_]+ [a-z_-]+ [0-9]+$' <<<"$runs"; then
  echo "::warning title=nightly-next tick::the tip ${tip:0:12}'s runs came back in an unexpected shape; nothing is re-run this tick"
  exit 0
fi
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
  # Out of attempts: a fresh run of the tip. Read the tip's runs again right before the dispatch,
  # so a replacement that started meanwhile is never doubled.
  if [[ "$(tip_runs | head -n1)" != "$id completed cancelled $attempt" ]]; then
    echo "nightly-next tip ${tip:0:12}: its runs changed since they were read; not dispatched"
    exit 0
  fi
  # The dispatch builds whatever nightly-next points at then: send it only while that is still the
  # tip whose runs were read, so the decision is about the commit that builds.
  if ! line="$(git ls-remote origin refs/heads/nightly-next)" || [[ "${line%%[[:space:]]*}" != "$tip" ]]; then
    echo "nightly-next tip ${tip:0:12}: nightly-next moved (or could not be read) since it was read; not dispatched, the next tick decides for the new tip"
    exit 0
  fi
  GH_BUDGET_WAIT_ATTEMPTS=1 gh workflow run nightly.yml -R "$repo" --ref nightly-next
  echo "::notice title=nightly-next tick::the tip ${tip:0:12}'s run $id was cancelled on attempt $attempt of $max_attempts; dispatched a fresh nightly.yml run of it on nightly-next, with every runner picked afresh"
  exit 0
fi

exec bash "$(dirname "$0")/nightly_next_rerun.sh" "$repo" "$id" "$attempt" "$tip" "the tip ${tip:0:12}'s run $id"
