#!/usr/bin/env bash
# Approve the deployment gate of the warmup run that belongs to YOUR Testbox,
# and nothing else.
#
# usage: scripts/blacksmith-testbox-approve.sh <tbx_id> <dispatch_epoch_seconds> [comment]
#
# Take <dispatch_epoch_seconds> with `date +%s` right BEFORE
# `blacksmith testbox warmup`.
#
# The run is bound to the box, never guessed:
#   1. Its title names this box. The warmup workflow sets
#      `run-name: cmux-tui Rust Testbox setup <tbx>`, so the waiting run says
#      which box it belongs to before any runner takes the job.
#   2. Or Blacksmith's record of this box shows the run URL
#      (`blacksmith testbox status --id <tbx>`). blacksmith 0.4.64 prints it
#      only after a runner takes the job, so this proof is usually missing
#      while the run waits at the gate.
# A run found only by its creation time is never approved: another operator's
# run can appear first inside any time window.
# The chosen run must also be the warmup workflow, event workflow_dispatch,
# ref main, status waiting, and triggered by the caller or Blacksmith's app.
# Every failure approves nothing and exits 3. Stop your box then and dispatch
# again.
set -euo pipefail

TBX="${1:?usage: blacksmith-testbox-approve.sh <tbx_id> <dispatch_epoch_seconds> [comment]}"
DISPATCHED_AT="${2:?usage: blacksmith-testbox-approve.sh <tbx_id> <dispatch_epoch_seconds> [comment]}"
COMMENT="${3:-blacksmith testbox warmup}"
REPO="${CMUX_TESTBOX_REPO:-manaflow-ai/cmux}"
WORKFLOW_FILE="cmux-tui-testbox-warmup.yml"
WORKFLOW_PATH=".github/workflows/$WORKFLOW_FILE"
TITLE_PREFIX="cmux-tui Rust Testbox setup"
WAIT_SECONDS="${CMUX_TESTBOX_APPROVE_WAIT:-150}"
POLL_SECONDS="${CMUX_TESTBOX_APPROVE_POLL:-5}"
SKEW_SECONDS=60

[[ "$TBX" =~ ^tbx_[A-Za-z0-9]+$ ]] || { echo "not a Testbox id: $TBX" >&2; exit 2; }
[[ "$DISPATCHED_AT" =~ ^[0-9]+$ ]] || { echo "dispatch time must be epoch seconds: $DISPATCHED_AT" >&2; exit 2; }

refuse() {
  echo "refusing to approve: $*" >&2
  echo "approve nothing; stop $TBX if it is yours and dispatch again" >&2
  exit 3
}

epoch_of() {
  python3 -c 'import sys,datetime; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).timestamp()))' "$1"
}

# Waiting warmup runs as "id<TAB>created_epoch<TAB>display_title" lines.
waiting_runs() {
  gh api "repos/$REPO/actions/workflows/$WORKFLOW_FILE/runs?event=workflow_dispatch&status=waiting&branch=main&per_page=100" \
    --jq '.workflow_runs[] | [.id, .created_at, .display_title] | @tsv' |
    while IFS=$'\t' read -r id created title; do
      printf '%s\t%s\t%s\n' "$id" "$(epoch_of "$created")" "$title"
    done
}

run_id=""
proof=""
deadline=$(( $(date +%s) + WAIT_SECONDS ))
while :; do
  runs="$(waiting_runs || true)"

  # 1. A run titled with this box.
  titled="$(printf '%s\n' "$runs" | awk -F'\t' -v want="$TITLE_PREFIX $TBX" '$3 == want {print $1}')"
  titled_count="$(printf '%s' "$titled" | grep -c . || true)"
  if (( titled_count > 1 )); then
    refuse "$titled_count waiting runs name $TBX: $(printf '%s' "$titled" | tr '\n' ' ')"
  fi
  if (( titled_count == 1 )); then run_id="$titled"; proof="title"; break; fi

  # 2. Blacksmith's record of this box.
  status_out="$(blacksmith testbox status --id "$TBX" 2>/dev/null || true)"
  url_run="$(printf '%s\n' "$status_out" | grep -F "$TBX" \
    | grep -Eo "github\.com/$REPO/actions/runs/[0-9]+" | grep -Eo '[0-9]+$' | head -1 || true)"
  if [[ -n "$url_run" ]]; then run_id="$url_run"; proof="run-url"; break; fi

  (( $(date +%s) < deadline )) || refuse "no waiting warmup run names $TBX and Blacksmith shows no run URL after ${WAIT_SECONDS}s (a run dispatched before the run-name change has no box in its title)"
  sleep "$POLL_SECONDS"
done

# Check the chosen run on GitHub.
run_json="$(gh api "repos/$REPO/actions/runs/$run_id")" || refuse "cannot read run $run_id"
[[ -n "$run_json" ]] || refuse "run $run_id not found"
field() { printf '%s' "$run_json" | jq -r "$1"; }
[[ "$(field .path)" == "$WORKFLOW_PATH"* ]] || refuse "run $run_id is not the warmup workflow ($(field .path))"
[[ "$(field .event)" == workflow_dispatch ]] || refuse "run $run_id event is $(field .event)"
[[ "$(field .head_branch)" == main ]] || refuse "run $run_id ref is $(field .head_branch), not main"
[[ "$(field .status)" == waiting ]] || refuse "run $run_id is $(field .status), not waiting at the gate"
title="$(field '.display_title // empty')"
if [[ "$title" == "$TITLE_PREFIX "* && "$title" != "$TITLE_PREFIX $TBX" ]]; then
  refuse "run $run_id names another box ($title)"
fi
created_epoch="$(epoch_of "$(field .created_at)")"
(( created_epoch + SKEW_SECONDS >= DISPATCHED_AT )) || refuse "run $run_id was created before this dispatch"
me="$(gh api user --jq .login 2>/dev/null || true)"
actor="$(field '.triggering_actor.login // .actor.login // empty')"
if [[ -n "$me" && -n "$actor" && "$actor" != "$me" && "$actor" != blacksmith* ]]; then
  refuse "run $run_id was triggered by $actor, not $me"
fi

env_id="$(gh api "repos/$REPO/actions/runs/$run_id/pending_deployments" --jq '.[0].environment.id // empty')"
[[ -n "$env_id" ]] || refuse "run $run_id has no pending deployment"
gh api -X POST "repos/$REPO/actions/runs/$run_id/pending_deployments" --input - >/dev/null <<JSON
{"environment_ids": [$env_id], "state": "approved", "comment": $(printf '%s' "$COMMENT" | jq -Rs .)}
JSON
echo "approved run $run_id for $TBX (proof: $proof)" >&2
echo "$run_id"
