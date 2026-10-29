#!/bin/bash
# Is nightly-next's tip still owed a build, right now? The last read before any write that builds it.
#
#   nightly_next_tip_owed.sh REPO TIP RUN_ID ATTEMPT
# Exit 0: still owed. nightly-next points at TIP, no run of TIP on nightly-next (push or dispatch) is
#         unfinished in any state (queued, in progress, waiting, pending, requested), and the newest of
#         them is RUN_ID, finished cancelled on ATTEMPT.
# Exit 1: not owed any more (the branch moved, another run carries TIP, or RUN_ID moved on); a message
#         on stdout says why.
# Exit 2: unreadable: a read failed or came back in an unexpected shape. The caller sends nothing.
#
# Both writes that build a cancelled tip call it immediately before the write: the re-run in
# nightly_next_rerun.sh and the fresh dispatch in nightly_next_cancelled_tip.sh. The reads before
# them may have waited out a rate limit, and meanwhile another tick, a rescue or a person may have
# started a run of the tip, or nightly-next may have moved on. Needs gh and jq.
set -uo pipefail

repo="${1:?usage: nightly_next_tip_owed.sh REPO TIP RUN_ID ATTEMPT}"
tip="${2:?}"
id="${3:?}"
attempt="${4:?}"

head="$(gh api "repos/$repo/git/ref/heads/nightly-next" \
  --jq 'if (.object.sha | type) == "string" and (.object.sha | test("^[0-9a-f]{40}$")) then .object.sha else error("not a commit") end')" \
  || { echo "nightly-next could not be read"; exit 2; }
if [[ "$head" != "$tip" ]]; then
  echo "nightly-next moved to ${head:0:12}"
  exit 1
fi

# Each page's workflow_runs must be an array of runs whose fields have their JSON types; anything
# else is a jq error and reads as unreadable.
runs="$(gh api --paginate "repos/$repo/actions/workflows/nightly.yml/runs?branch=nightly-next&head_sha=$tip&per_page=100" \
  --jq 'if (.workflow_runs | type) == "array" then .workflow_runs[] else error("not a list") end | if (.id | type) == "number" and (.event | type) == "string" and (.status | type) == "string" and (.run_attempt | type) == "number" and ((.conclusion | type) == "string" or .conclusion == null) then . else error("a run of an unexpected shape") end | select(.event == "push" or .event == "workflow_dispatch") | "\(.id) \(.status) \(.conclusion // "-") \(.run_attempt)"' | sort -rn)" \
  || { echo "the tip's runs could not be read"; exit 2; }
if grep -Evq '^[0-9]+ [a-z_]+ [a-z_-]+ [0-9]+$' <<<"$runs"; then
  echo "the tip's runs came back in an unexpected shape"
  exit 2
fi
if carrier="$(grep -v ' completed ' <<<"$runs" | head -n1)" && [[ -n "$carrier" ]]; then
  echo "run ${carrier%% *} carries the tip"
  exit 1
fi
if [[ "$(head -n1 <<<"$runs")" != "$id completed cancelled $attempt" ]]; then
  echo "run $id is no longer the tip's newest cancelled run (newest: '$(head -n1 <<<"$runs")')"
  exit 1
fi
exit 0
