#!/usr/bin/env bash
# Prints the commit the base autofix diffs from: the head of the newest successful push run on BRANCH
# that made its own Mac exports. Such a run's autofix job uploads the `base-autofix-own-exports` marker
# artifact (cmux-next-base-autofix.yml). A run that left its exports to another run's queued or running
# Mac job (base-autofix-mac-busy.sh) ends green with its "Mac exports deferred" job but exported nothing,
# and uploads no marker, so the next run reaches past it and its changes stay in range; so does the run of
# this workflow's own repair push, whose jobs all skip (cmux-next-base-autofix.yml, No loop).
#
# Two listings, the successful runs and the markers: reading each run's jobs instead cost one GITHUB_TOKEN
# call per run (on 2026-11-22 all 30 listed runs had deferred: 31 calls, twice a run, to print nothing),
# from the hour the production promote gates read their staging runs from.
#
# Prints nothing when no run qualifies or GitHub can't be read; the caller then runs every repair. A
# missing marker (one that expired, or a run from before the marker) only widens the range the same way.
set -uo pipefail

branch="${1:-feat-cmux-next}"
repo="${GITHUB_REPOSITORY:-manaflow-ai/cmux}"
marker="base-autofix-own-exports"

runs="$(gh api "repos/$repo/actions/workflows/cmux-next-base-autofix.yml/runs?branch=$branch&event=push&status=success&per_page=30" \
  --jq '.workflow_runs[] | "\(.id) \(.head_sha)"' 2>/dev/null)" || exit 0
[[ -n "$runs" ]] || exit 0
own="$(gh api "repos/$repo/actions/artifacts?name=$marker&per_page=100" --jq '.artifacts[].workflow_run.id' 2>/dev/null)" || exit 0
while read -r run sha; do
  [[ -n "$run" ]] || continue
  if grep -qxF -- "$run" <<<"$own"; then
    echo "$sha"
    exit 0
  fi
done <<<"$runs"
