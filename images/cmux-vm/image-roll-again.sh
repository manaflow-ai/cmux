#!/usr/bin/env bash
# Dispatches a roll of the same cmux-tui build again when promote found that feat-cmux-next moved its image inputs
# while the bake ran (image-roll-push.sh's result "moved", approve's exit 4). cloud-vm-image-roll.yml's report job
# runs it for a dispatched roll (a pinned build); a push roll only rebakes the tip, which the commit that moved it
# already started.
#
# Roll 45142787545 (2026-11-23) baked cmux-tui 227a607b; an image-input commit landed at 09:30Z mid-bake, approve
# refused the candidate and the run ended green with the build dropped. The push roll that commit started rebaked
# the old pin, so production's image stayed on the older cmux-tui until another build dispatched (lag 276 min).
#
#   PIN=<40-hex> AGAIN=<n> DRY_RUN_INPUT=auto GH_TOKEN=... GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=1 image-roll-again.sh
#
# It dispatches nothing when:
# - a dispatched roll is already waiting: it carries this build or a newer one, and a new dispatch would replace it;
# - this build was rolled again 3 times already (AGAIN): the tip keeps moving, and the next build or the
#   cloud-vm-image-roll-catch-up.yml cron on main rolls it later.
# A waiting push roll is replaced, which is fine: this roll bakes the same tip with the newer pin.
set -euo pipefail
pin="${PIN:-}"
[[ "$pin" =~ ^[0-9a-f]{40}$ ]] || { echo "::error title=Cloud VM image roll::the plan's pin is not a commit: '${pin}'"; exit 1; }
repo="${GITHUB_REPOSITORY:?}"
run="${GITHUB_RUN_ID:?}"
[[ "$run" =~ ^[0-9]{1,20}$ ]] || { echo "image-roll-again: bad run id" >&2; exit 2; }
again="${AGAIN:-0}"
[[ "$again" =~ ^[0-9]{1,3}$ ]] || again=0
dry_run="${DRY_RUN_INPUT:-auto}"
case "$dry_run" in auto|true|false) ;; *) dry_run=auto ;; esac
workflow=cloud-vm-image-roll.yml

if [ "$again" -ge 3 ]; then
  echo "::warning title=Cloud VM image roll::cmux-tui ${pin:0:12} was rolled again ${again} times and the tip moved its image inputs under every bake; the next build or the catch-up rolls it"
  exit 0
fi
waiting="$(gh api "repos/${repo}/actions/workflows/${workflow}/runs?branch=feat-cmux-next&event=workflow_dispatch&per_page=20" \
  --jq "[.workflow_runs[] | select(.status != \"completed\" and .id != ${run}) | .id] | first // empty")"
if [ -n "$waiting" ]; then
  echo "A dispatched roll is already waiting (run ${waiting}); it rolls this build or a newer one, so nothing is dispatched"
  exit 0
fi
gh api -X POST "repos/${repo}/actions/workflows/${workflow}/dispatches" -f ref=refs/heads/feat-cmux-next \
  -f "inputs[commit]=${pin}" -f "inputs[dry_run]=${dry_run}" -f "inputs[again]=$((again + 1))" > /dev/null
echo "The tip moved its image inputs during the bake: dispatched a roll of cmux-tui ${pin:0:12} again (time $((again + 1)) of 3)"
