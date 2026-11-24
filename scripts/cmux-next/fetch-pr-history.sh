#!/usr/bin/env bash
# The history a PR autofix job reads, and no more: from the merge commit, the base and the head back to
# the base and head's merge base, commits and trees (no blobs).
#
# Usage: scripts/cmux-next/fetch-pr-history.sh MERGE_SHA BASE_SHA HEAD_SHA [REMOTE]
#
# The jobs read the changed paths (BASE...HEAD), the stale-inputs guard (check-generator-inputs.sh: the merge
# commit's parents and their merge base) and the base commit's scripts. All of it sits between the three tips
# and that merge base. A depth 1 checkout, then deeper fetches of the three tips (CMUX_PR_HISTORY_DEPTHS,
# default 64 512 4096) until `git merge-base BASE HEAD` finds a commit, then the whole history as the last
# resort.
#
# Why: fetch-depth 0 fetched every branch's commit graph (about 32,000 branches): 150 s median on the GCP pool
# and on Freestyle VMs a fetch that sent nothing for 60 s, so git gave up (`curl 28 Operation too slow`, `bad pack
# header`) three times: 25 of 37 autofix repairs runs there failed on 2026-11-23 00:55-03:36Z. The unshallowed
# merge commit's history (all of feat-cmux-next) took 823 s median there for action-areas.
#
# Each fetch gets three tries; a fetch that still fails fails the script, as the checkout it replaces did.
set -euo pipefail
merge="${1:?usage: $0 MERGE_SHA BASE_SHA HEAD_SHA [REMOTE]}"
base="${2:?usage: $0 MERGE_SHA BASE_SHA HEAD_SHA [REMOTE]}"
head="${3:?usage: $0 MERGE_SHA BASE_SHA HEAD_SHA [REMOTE]}"
remote="${4:-origin}"
read -r -a depths <<< "${CMUX_PR_HISTORY_DEPTHS:-64 512 4096}"

found() {
  git cat-file -e "$base^{commit}" 2>/dev/null && git cat-file -e "$head^{commit}" 2>/dev/null &&
    git merge-base "$base" "$head" >/dev/null 2>&1
}

fetch() {
  local try
  for try in 1 2 3; do
    # An unshallow try that completed the history before failing needs no other.
    [[ "${1:-}" == --unshallow && "$(git rev-parse --is-shallow-repository)" == false ]] && return 0
    git fetch --no-tags --quiet --filter=blob:none "$@" "$remote" "$merge" "$base" "$head" && return 0
    echo "::warning::history fetch $* failed (try $try of 3)"
    sleep $((try * ${CMUX_PR_HISTORY_RETRY_S:-10}))
  done
  return 1
}

if [[ "$(git rev-parse --is-shallow-repository)" == false ]]; then
  # A reused workspace with whole history: only the tips it lacks.
  found || fetch
  found || { echo "::error::no merge base of $base and $head" >&2; exit 1; }
  echo "history: already whole"
  exit 0
fi
for depth in "${depths[@]}"; do
  fetch --depth="$depth"
  if found; then
    echo "history: depth $depth reaches the merge base $(git merge-base "$base" "$head")"
    exit 0
  fi
done
fetch --unshallow
found || { echo "::error::no merge base of $base and $head in the whole history" >&2; exit 1; }
echo "history: whole (the merge base is over ${depths[-1]} commits back)"
