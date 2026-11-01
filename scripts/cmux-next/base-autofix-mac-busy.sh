#!/usr/bin/env bash
# Whether another cmux-next base autofix run already carries the Mac exports: its pushed-exports job
# (waiting for the push's packed exports) or its Mac action-exports job is queued or running
# (cmux-next-base-autofix.yml's action export areas job).
#
# The Mac job had a concurrency group with cancel-in-progress false, so a newer push replaced it only
# while it was pending. But with the Mac runners saturated, every job waited minutes for a runner and
# the next push replaced it before it started: from 11:15Z to 11:36Z on 2026-10-21 every run's Mac job
# was cancelled without a runner, and no settings or action export landed after 02:14Z. Now the job has
# no group, so a queued one keeps its place, and a run skips its own Mac job while another one is
# queued or running: that job regenerates on the newest tip when it starts (base-autofix-settings-
# exports.sh), and the run ends green with its "Mac exports deferred" job, which base-autofix-since.sh
# passes over, so the next run's "since" still covers its changes.
#
# The pushed-exports job counts the same way: it waits up to 45 minutes for the pack, and every run's
# autofix needs it. With only the Mac job counted, every run waited there (2026-11-01: 485 of 532 runs,
# autofix starting a median 63 minutes after its push), so a webviews or cargo formatting repair that
# needs no export sat behind the wait, and the waits' polling ran the read App out of budget (HTTP 403,
# so most lookups missed anyway). Now one run waits for the exports and every other run repairs the rest
# at once, as it did when only the Mac job carried them.
#
# Prints mac_busy=true and mac_busy_run=RUN when another run's pushed-exports or Mac job is not
# completed, else mac_busy=false. A read that fails prints mac_busy=false: two waits beat none.
#
# Usage: GH_TOKEN=... base-autofix-mac-busy.sh RUN_ID [BRANCH]   (GITHUB_REPOSITORY: owner/repo)
set -uo pipefail
self="${1:?usage: $0 RUN_ID [BRANCH]}"
branch="${2:-feat-cmux-next}"
repo="${GITHUB_REPOSITORY:-manaflow-ai/cmux}"
mac_job="action exports (Mac)"
pushed_job="exports from the push's generated files"

runs="$(gh api "repos/$repo/actions/workflows/cmux-next-base-autofix.yml/runs?branch=$branch&event=push&per_page=100" \
  --jq '.workflow_runs[] | select(.status != "completed") | .id' 2>/dev/null)" || runs=""
for run in $runs; do
  [[ "$run" == "$self" ]] && continue
  open="$(gh api "repos/$repo/actions/runs/$run/jobs?per_page=100" \
    --jq "[.jobs[] | select((.name == \"$mac_job\" or .name == \"$pushed_job\") and .status != \"completed\")] | length" 2>/dev/null)" || open=0
  if [[ "$open" =~ ^[0-9]+$ ]] && ((open > 0)); then
    echo "mac_busy=true"
    echo "mac_busy_run=$run"
    exit 0
  fi
done
echo "mac_busy=false"
