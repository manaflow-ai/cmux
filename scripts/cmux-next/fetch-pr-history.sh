#!/usr/bin/env bash
# The history a PR autofix job reads, and no more: from the merge commit, the base and the head back to
# the base and head's merge base, commits and trees (no blobs).
#
# Usage: scripts/cmux-next/fetch-pr-history.sh MERGE_SHA BASE_SHA HEAD_SHA [REMOTE]
#
# The jobs read the changed paths (BASE...HEAD), the stale-inputs guard (check-generator-inputs.sh: the merge
# commit's parents and their merge base) and the base commit's scripts. All of it sits between the three tips
# and that merge base, and on the merge commit's base side back to BASE. A depth 1 checkout, then deeper fetches
# of the three tips (CMUX_PR_HISTORY_DEPTHS, default 64 512 4096) until `git merge-base BASE HEAD` finds a commit
# and BASE is an ancestor of the merge commit's first parent, then the whole history as the last resort.
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

# The guard also walks from the merge commit's base side (GitHub's first parent) back to BASE: the event's base
# can be older than the base GitHub merged onto. A head already merged up to BASE finds its merge base at once,
# while that base side lay 134 commits past BASE (cmux#50412, 2026-11-23): depth 64 stopped short, and the guard
# read BASE as no ancestor of either side and exited 1 with no message.
reached() {
  found || return 1
  git cat-file -e "$merge^2" 2>/dev/null || return 0
  git merge-base --is-ancestor "$base" "$merge^1" 2>/dev/null
}

fetch() {
  local try
  for try in 1 2 3; do
    # An unshallow try that completed the history before failing needs no other.
    [[ "${1:-}" == --unshallow && "$(git rev-parse --is-shallow-repository)" == false ]] && return 0
    git fetch --no-recurse-submodules --no-tags --quiet --filter=blob:none "$@" "$remote" "$merge" "$base" "$head" && return 0
    echo "::warning::history fetch $* failed (try $try of 3)"
    sleep $((try * ${CMUX_PR_HISTORY_RETRY_S:-10}))
  done
  return 1
}

# A cloud runner VM's image holds this repository's commits and trees (a git object store, CMUX_PR_HISTORY_STORE
# overrides its path): the history comes from there first, on the VM's own disk, so the fetches below send only the
# tips the store lacks. No store, a shallow store, or any failure here leaves those fetches to do all of it.
repo="${GITHUB_REPOSITORY:-manaflow-ai/cmux}"
store="${CMUX_PR_HISTORY_STORE:-/var/cache/fsr/git/${repo/\//--}.git}"
if [[ -d "$store/objects" && ! -s "$store/shallow" && "$(git rev-parse --is-shallow-repository)" == true ]]; then
  # Fetched by path, so no remote is configured; the refs it writes are the store's branches.
  # The store itself may lack blobs (a blob-less clone): its upload-pack must honour the filter, never fetch lazily.
  GIT_NO_LAZY_FETCH=1 git fetch --no-recurse-submodules --no-tags --quiet --filter=blob:none --unshallow \
    --upload-pack='git -c uploadpack.allowFilter=true upload-pack' "$store" \
    '+refs/heads/*:refs/remotes/pr-history-store/*' || echo "::notice::history store fetch failed; fetching from $remote"
  # The store lacks the PR's merge commit, so the checkout's shallow boundary stays at it. When the store gave every
  # parent of a boundary commit (with the store's whole history behind it), that commit is no longer a boundary.
  shallow_file="$(git rev-parse --git-path shallow)"
  if [[ -s "$shallow_file" ]]; then
    keep=()
    while read -r sha; do
      whole=true
      for parent in $(git cat-file -p "$sha" 2>/dev/null | sed -n 's/^parent //p'); do
        GIT_NO_LAZY_FETCH=1 git cat-file -e "$parent^{commit}" 2>/dev/null || whole=false
      done
      [[ "$whole" == true ]] || keep+=("$sha")
    done < "$shallow_file"
    if ((${#keep[@]})); then printf '%s\n' "${keep[@]}" > "$shallow_file"; else rm -f "$shallow_file"; fi
  fi
fi

if [[ "$(git rev-parse --is-shallow-repository)" == false ]]; then
  # A reused workspace (or the store's history) with whole history: only the tips it lacks.
  found || fetch
  found || { echo "::error::no merge base of $base and $head" >&2; exit 1; }
  echo "history: already whole"
  exit 0
fi
for depth in "${depths[@]}"; do
  fetch --depth="$depth"
  if reached; then
    echo "history: depth $depth reaches the merge base $(git merge-base "$base" "$head")"
    exit 0
  fi
done
fetch --unshallow
found || { echo "::error::no merge base of $base and $head in the whole history" >&2; exit 1; }
echo "history: whole (the merge base is over ${depths[-1]} commits back)"
