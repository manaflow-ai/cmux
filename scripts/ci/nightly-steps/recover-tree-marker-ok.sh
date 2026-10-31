#!/usr/bin/env bash
# NIGHTLY_NEXT_TREE_AT_INSTALL: whether nightly-next run <run id> may be recovered.
# A build made before its cmux-tui tree published is publishable only once its run's
# await-nightly-tree-marker passed (the marker names its client's commit as the tree's
# publisher). Exit 0 when that job passed, was skipped or never existed; 1 (printing why)
# when it failed, was cancelled or has not finished, or the run's jobs cannot be read.
# Env: GITHUB_REPOSITORY, GH_TOKEN (actions: read).
set -euo pipefail
run_id="${1:?usage: recover-tree-marker-ok.sh <run id>}"
[[ "$run_id" =~ ^[0-9]+$ ]] || { echo "not a run id: $run_id"; exit 1; }
# One bounded read: a nightly run has fewer than 100 jobs, and filter=latest keeps re-runs out.
if ! states="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run_id/jobs?per_page=100&filter=latest" \
    --jq '.jobs[] | select(.name == "await-nightly-tree-marker") | .conclusion // "pending"' </dev/null 2>/dev/null)"; then
  echo "its jobs cannot be read"
  exit 1
fi
bad="$(grep -vxE 'success|skipped' <<<"$states" | sort -u | tr '\n' ' ' || true)"
[[ -z "${bad// /}" ]] || { echo "its cmux-tui tree marker check is ${bad% }"; exit 1; }
