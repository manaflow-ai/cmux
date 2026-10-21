#!/usr/bin/env bash
# Prints the commit the base autofix diffs from: the head of the newest successful push run on BRANCH
# that made its own Mac exports. A run that left them to another run's queued or running Mac job
# (base-autofix-mac-busy.sh) ends green with its "Mac exports deferred" job, but exported nothing, so
# the next run reaches past it and its changes stay in range. A run whose jobs can't be read is passed
# over too. Prints nothing when no run qualifies or GitHub can't be read; the caller then runs every repair.
set -uo pipefail

branch="${1:-feat-cmux-next}"
repo="${GITHUB_REPOSITORY:-manaflow-ai/cmux}"
marker="Mac exports deferred"

runs="$(gh api "repos/$repo/actions/workflows/cmux-next-base-autofix.yml/runs?branch=$branch&event=push&status=success&per_page=30" \
  --jq '.workflow_runs[] | "\(.id) \(.head_sha)"' 2>/dev/null)" || exit 0
while read -r run sha; do
  [[ -n "$run" ]] || continue
  deferred="$(gh api "repos/$repo/actions/runs/$run/jobs?per_page=100" \
    --jq "[.jobs[] | select(.name == \"$marker\" and .conclusion == \"success\")] | length" 2>/dev/null)" || continue
  if [[ "$deferred" == 0 ]]; then
    echo "$sha"
    exit 0
  fi
done <<<"$runs"
