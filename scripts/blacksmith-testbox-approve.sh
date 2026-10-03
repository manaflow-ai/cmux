#!/usr/bin/env bash
# Approve the deployment gate of the warmup run that belongs to YOUR Testbox,
# and nothing else.
#
# usage: scripts/blacksmith-testbox-approve.sh <tbx_id> <dispatch_epoch_seconds> [comment]
#
# Ownership is proven, never guessed:
#   1. The run id comes from Blacksmith's own record of this Testbox
#      (`blacksmith testbox status --id <tbx>` prints the box's RUN URL), not
#      from a list of waiting runs: a list is paged (30 runs by default) and
#      shared by every agent in the lane, so a set difference against it can
#      pick a stranger's run.
#   2. The run must then match on GitHub: the warmup workflow, event
#      workflow_dispatch, head branch main, created no earlier than the
#      dispatch time (minus 60 s for clock skew), status waiting, and the
#      triggering actor equal to the caller's own GitHub login when GitHub
#      reports one.
# If any check fails, or the box shows no run URL within the wait, the
# script approves nothing, prints why, and exits 3. Stop your box then, and
# approve by hand only a run you can prove is yours.
set -euo pipefail

TBX="${1:?usage: blacksmith-testbox-approve.sh <tbx_id> <dispatch_epoch_seconds> [comment]}"
DISPATCHED_AT="${2:?usage: blacksmith-testbox-approve.sh <tbx_id> <dispatch_epoch_seconds> [comment]}"
COMMENT="${3:-blacksmith testbox warmup}"
REPO="${CMUX_TESTBOX_REPO:-manaflow-ai/cmux}"
WORKFLOW_PATH=".github/workflows/cmux-tui-testbox-warmup.yml"
WAIT_SECONDS="${CMUX_TESTBOX_APPROVE_WAIT:-150}"
SKEW_SECONDS=60

[[ "$TBX" =~ ^tbx_[A-Za-z0-9]+$ ]] || { echo "not a Testbox id: $TBX" >&2; exit 2; }
[[ "$DISPATCHED_AT" =~ ^[0-9]+$ ]] || { echo "dispatch time must be epoch seconds: $DISPATCHED_AT" >&2; exit 2; }

refuse() {
  echo "refusing to approve: $*" >&2
  echo "approve nothing; stop $TBX if it is yours and dispatch again" >&2
  exit 3
}

# 1. The run id from Blacksmith's record of this box.
run_id=""
deadline=$(( $(date +%s) + WAIT_SECONDS ))
while :; do
  status_out="$(blacksmith testbox status --id "$TBX" 2>/dev/null || true)"
  run_id="$(printf '%s\n' "$status_out" | grep -F "$TBX" \
    | grep -Eo "github\.com/$REPO/actions/runs/[0-9]+" | grep -Eo '[0-9]+$' | head -1 || true)"
  [[ -n "$run_id" ]] && break
  (( $(date +%s) < deadline )) || refuse "Testbox $TBX shows no run URL after ${WAIT_SECONDS}s"
  sleep 5
done

# 2. The run must look exactly like the run this caller dispatched.
run_json="$(gh api "repos/$REPO/actions/runs/$run_id")" || refuse "cannot read run $run_id"
field() { printf '%s' "$run_json" | jq -r "$1"; }
[[ "$(field .path)" == "$WORKFLOW_PATH"* ]] || refuse "run $run_id is not the warmup workflow ($(field .path))"
[[ "$(field .event)" == workflow_dispatch ]] || refuse "run $run_id event is $(field .event)"
[[ "$(field .head_branch)" == main ]] || refuse "run $run_id ref is $(field .head_branch), not main"
[[ "$(field .status)" == waiting ]] || refuse "run $run_id is $(field .status), not waiting at the gate"
created_at="$(field .created_at)"
created_epoch="$(python3 -c 'import sys,datetime; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).timestamp()))' "$created_at")"
(( created_epoch + SKEW_SECONDS >= DISPATCHED_AT )) \
  || refuse "run $run_id was created at $created_at, before this dispatch"
me="$(gh api user --jq .login 2>/dev/null || true)"
actor="$(field '.triggering_actor.login // .actor.login // empty')"
if [[ -n "$me" && -n "$actor" && "$actor" != "$me" ]]; then
  # Blacksmith dispatches on our behalf as its app; only a human or bot that is
  # not the caller and not Blacksmith's app means someone else's run.
  [[ "$actor" == blacksmith* ]] || refuse "run $run_id was triggered by $actor, not $me"
fi

# 3. Approve exactly that run.
env_id="$(gh api "repos/$REPO/actions/runs/$run_id/pending_deployments" --jq '.[0].environment.id // empty')"
[[ -n "$env_id" ]] || refuse "run $run_id has no pending deployment"
gh api -X POST "repos/$REPO/actions/runs/$run_id/pending_deployments" --input - >/dev/null <<JSON
{"environment_ids": [$env_id], "state": "approved", "comment": $(printf '%s' "$COMMENT" | jq -Rs .)}
JSON
echo "approved run $run_id for $TBX"
echo "$run_id"
