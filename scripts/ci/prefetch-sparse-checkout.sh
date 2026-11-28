#!/usr/bin/env bash
# Widen a blob:none sparse checkout to the non-cone patterns on stdin, fetching their blobs in parallel.
#
# A blob:none checkout of a wide sparse set fetches every missing blob in ONE request at `git checkout`:
# GitHub spends about 28 s packing 33,000 wanted blobs and git 9 s indexing them (path_route, 41 s of its
# 58 s run, 2026-11-24). Split over PREFETCH_JOBS parallel fetches the same blobs arrive in about 5 s.
# The checkout before this one takes only this script and its pattern list; this script prefetches the blobs the index's entries under them name, then applies the patterns. A blob the prefetch missed (a pattern
# this script reads more narrowly than git does, a fetch failed PREFETCH_TRIES times) is still fetched lazily by the sparse checkout,
# so the working tree is exactly what a checkout of these patterns gives, only slower.
#
# Usage: prefetch-sparse-checkout.sh < PATTERNS_FILE   (path_route: scripts/ci/path-route-sparse-checkout.txt)
# GH_TOKEN, when set, authenticates the fetches.
set -euo pipefail

jobs="${PREFETCH_JOBS:-16}"
if [[ -n "${GH_TOKEN:-}" ]]; then
  # Through the environment, not argv: every git child (the lazy fetch of the sparse checkout too) inherits it.
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
  GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
  export GIT_CONFIG_VALUE_0
fi

# A non-cone pattern as a pathspec: /dir/ -> dir/**, /a/*/b -> a/*/b, !/x/**/*.png -> an exclude.
patterns=()
specs=()
while IFS= read -r line || [[ -n "$line" ]]; do
  patterns+=("$line")
  [[ -z "$line" || "$line" == \#* ]] && continue
  magic=glob
  if [[ "$line" == !* ]]; then magic=exclude,glob; line="${line#!}"; fi
  line="${line#/}"
  [[ "$line" == */ ]] && line="${line}**"
  specs+=(":($magic)$line")
done

# A pool runner can lose its default `/tmp` between jobs. Prefer the runner's or user's existing root,
# then keep the fallback inside this checkout so local use does not depend on host setup.
temp_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
fallback_parent="$PWD/.cmux-prefetch"
cleanup_parent=
if [[ ! -d "$temp_parent" || ! -w "$temp_parent" || ! -x "$temp_parent" ]]; then
  mkdir -p "$fallback_parent"
  temp_parent="$fallback_parent"
  cleanup_parent="$fallback_parent"
fi
work="$(mktemp -d "$temp_parent/prefetch.XXXXXXXX")"
cleanup() {
  rm -rf "$work"
  [[ -n "$cleanup_parent" ]] && rmdir "$cleanup_parent" 2>/dev/null || true
}
trap cleanup EXIT
start=$SECONDS
# Regular files and symlinks only (160000 is a gitlink, which has no blob).
git ls-files -s -- "${specs[@]}" | awk '$1 != "160000" { print $2 }' | sort -u > "$work/oids"
count=$(wc -l < "$work/oids")
# A full clone (a pool VM's checkout borrowing its local mirror) has every blob already, and `fetch --filter`
# outside a partial clone is an error: only apply the patterns there.
if [[ -z "$(git config --get extensions.partialClone || git config --get-regexp '^remote\..*\.promisor$' || true)" ]]; then
  echo "sparse prefetch: not a partial clone, nothing to fetch"
  count=0
fi
if (( count > 0 )); then
  split -n "l/$jobs" "$work/oids" "$work/chunk."
  # A fetch GitHub stalls (no byte for PREFETCH_STALL_S seconds) is dropped and tried again, PREFETCH_TRIES
  # times in all, so one slow pack does not hold the job until the lazy fetch of the sparse checkout takes it alone.
  fetch_chunk() {
    local try
    for (( try = 1; try <= ${PREFETCH_TRIES:-3}; try++ )); do
      git -c fetch.negotiationAlgorithm=noop -c http.lowSpeedLimit=1 -c "http.lowSpeedTime=${PREFETCH_STALL_S:-30}" \
        fetch -q origin --no-tags --no-write-fetch-head --recurse-submodules=no --filter=blob:none --stdin \
        < "$1" && return 0
      echo "sparse prefetch: $(basename "$1") failed (try $try)" >&2
    done
    return 1
  }
  pids=()
  for chunk in "$work"/chunk.*; do
    [[ -s "$chunk" ]] || continue
    fetch_chunk "$chunk" & pids+=("$!")
  done
  failed=0
  for pid in "${pids[@]}"; do wait "$pid" || failed=$((failed + 1)); done
  (( failed == 0 )) || echo "::warning::sparse prefetch: $failed of ${#pids[@]} blob fetches failed; the checkout fetches the rest lazily"
fi
echo "sparse prefetch: $count blobs in $jobs fetches, $((SECONDS - start)) s"

# Let Git enable sparse checkout in the worktree that owns the index. A reused runner can
# have core.sparseCheckout=false in config.worktree, which overrides repository config.
# Pass patterns as arguments so a Git transport retry can replay the whole selection.
git sparse-checkout set --no-cone -- "${patterns[@]}"
echo "sparse checkout: $(git ls-files -t | grep -vc '^S ') files on disk, $((SECONDS - start)) s in all"
