#!/usr/bin/env bash
# Starts the cmux-tui artifacts run of a branch head that github-actions[bot] pushed.
#
# A push made with a job's GITHUB_TOKEN starts no workflow, so a base autofix
# commit (cmux-next-base-autofix.yml) never had a cmux-tui-artifacts.yml run:
# a dev build or sweep of that tip waited on its tree and failed with "no
# cmux-tui artifacts run exists" (42ef622e4a11, 3f13f5fcf68b, daf5324aad91,
# 9325972a0a07 and eb31e46c64c4 on 2026-10-24: none has a run). A
# workflow_dispatch made with the same token does start a run, so after a bot
# push this dispatches one on the branch when its head is a bot commit with no
# run. The run's tree preflight stops within minutes when the tree is
# published already (an autofix that changes no cmux-tui input).
#
# Usage: publish-bot-head-tree.sh [branch]   (default feat-cmux-next)
# Env: GH_TOKEN (actions: write), GITHUB_REPOSITORY. It never fails the job
# that pushed: an API error prints a warning and exits 0.
set -euo pipefail
branch="${1:-feat-cmux-next}"
repo="${GITHUB_REPOSITORY:-manaflow-ai/cmux}"
bot="github-actions[bot]"
warn() { echo "warning: $*; no cmux-tui artifacts run was started for the $branch head" >&2; exit 0; }

head="$(gh api "repos/$repo/commits/$branch" --jq '.sha + " " + (.author.login // "")' 2>/dev/null)" \
  || warn "cannot read the $branch head"
sha="${head%% *}"
login="${head#* }"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || warn "the $branch head is not a commit sha ('$sha')"
if [[ "$login" != "$bot" ]]; then
  echo "$branch head ${sha:0:12} is not a $bot commit: its push started its own cmux-tui artifacts run."
  exit 0
fi
runs="$(gh api "repos/$repo/actions/workflows/cmux-tui-artifacts.yml/runs?head_sha=$sha&per_page=1" --jq .total_count 2>/dev/null)" \
  || warn "cannot read the cmux-tui artifacts runs of ${sha:0:12}"
if [[ "$runs" != 0 ]]; then
  echo "$branch head ${sha:0:12} has a cmux-tui artifacts run already."
  exit 0
fi
gh workflow run cmux-tui-artifacts.yml --repo "$repo" --ref "$branch" >/dev/null 2>&1 \
  || warn "the dispatch of cmux-tui-artifacts.yml on $branch failed (the token needs actions: write)"
echo "Dispatched cmux-tui-artifacts.yml on $branch for its $bot head ${sha:0:12} (a GITHUB_TOKEN push starts no run)."
