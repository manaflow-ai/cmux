#!/usr/bin/env bash
# Fetch one branch's full history, without blobs, into a checkout that actions/checkout left shallow.
#
#   scripts/ci/fetch_branch_history.sh [branch=feat-cmux-next] [repo dir=.]
#
# actions/checkout with fetch-depth: 0 fetches +refs/heads/* and +refs/tags/* (80,000+ refs here). On
# 2026-11-23 that fetch stalled under 1000 B/s and died "bad pack header" on all three of checkout's tries
# in browser-host release (jobs 137965629300, 137939822556, 137925913638), the Cloudflare relay plan
# (137746568589) and the web bundle publish (137969522125). A job that needs ancestry checks out the tip
# (the default depth 1) and calls this: one branch, --no-tags, blob:none (blob:none, not tree:0: git
# 2.55/2.56 aborts in pack-objects on a treeless --unshallow, run 43863985334), three tries.
set -euo pipefail
branch="${1:-feat-cmux-next}"
dir="${2:-.}"
# A reused pool workspace can hold full history already, and --unshallow refuses a complete repository.
unshallow=()
if [ "$(git -C "$dir" rev-parse --is-shallow-repository)" = true ]; then unshallow=(--unshallow); fi
for try in 1 2 3; do
  if git -C "$dir" -c protocol.version=2 fetch --no-tags --no-recurse-submodules --filter=blob:none "${unshallow[@]}" origin \
    "+refs/heads/$branch:refs/remotes/origin/$branch"; then
    exit 0
  fi
  echo "fetch of $branch's history: try $try failed; retrying" >&2
  sleep $((try * 15))
  # A failed --unshallow can leave the repository complete; recheck before the next try.
  unshallow=()
  if [ "$(git -C "$dir" rev-parse --is-shallow-repository)" = true ]; then unshallow=(--unshallow); fi
done
echo "::error::could not fetch $branch's history after three tries" >&2
exit 1
