#!/usr/bin/env bash
# Whether another cmux-next base autofix run already has its Mac action-exports job queued or running
# (cmux-next-base-autofix.yml's action export areas job).
#
# The Mac job had a concurrency group with cancel-in-progress false, so a newer push replaced it only
# while it was pending. But with the Mac runners saturated, every job waited minutes for a runner and
# the next push replaced it before it started: from 11:15Z to 11:36Z on 2026-10-21 every run's Mac job
# was cancelled without a runner, and no settings or action export landed after 02:14Z. Now the job has
# no group, so a queued one keeps its place, and a run skips its own Mac job while another one is
# queued or running: that job regenerates on the newest tip when it starts (base-autofix-settings-
# exports.sh), and a run that skipped fails, so the next run's "since" still covers its changes.
#
# Prints mac_busy=true and mac_busy_run=RUN when another run's Mac job is not completed, else
# mac_busy=false. A read that fails prints mac_busy=false: two Mac jobs beat none.
#
# Usage: GH_TOKEN=... base-autofix-mac-busy.sh RUN_ID [BRANCH]   (GITHUB_REPOSITORY: owner/repo)
set -uo pipefail
self="${1:?usage: $0 RUN_ID [BRANCH]}"
branch="${2:-feat-cmux-next}"
repo="${GITHUB_REPOSITORY:-manaflow-ai/cmux}"
job="action exports (Mac)"

runs="$(gh api "repos/$repo/actions/workflows/cmux-next-base-autofix.yml/runs?branch=$branch&event=push&per_page=100" \
  --jq '.workflow_runs[] | select(.status != "completed") | .id' 2>/dev/null)" || runs=""
for run in $runs; do
  [[ "$run" == "$self" ]] && continue
  open="$(gh api "repos/$repo/actions/runs/$run/jobs?per_page=100" \
    --jq "[.jobs[] | select(.name == \"$job\" and .status != \"completed\")] | length" 2>/dev/null)" || open=0
  if [[ "$open" =~ ^[0-9]+$ ]] && ((open > 0)); then
    echo "mac_busy=true"
    echo "mac_busy_run=$run"
    exit 0
  fi
done
echo "mac_busy=false"
