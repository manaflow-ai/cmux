#!/usr/bin/env bash
# Widen a blob:none sparse checkout to the non-cone patterns on stdin, fetching their blobs in parallel.
#
# A blob:none checkout of a wide sparse set fetches every missing blob in ONE request at `git checkout`:
# GitHub spends about 28 s packing 33,000 wanted blobs and git 9 s indexing them (path_route, 41 s of its
# 58 s run, 2026-11-24). Split over PREFETCH_JOBS parallel fetches the same blobs arrive in about 5 s.
# The checkout before this one takes only this script and its pattern list; this script writes the
# patterns, prefetches the blobs the index's entries under them name, then applies the patterns. A blob the prefetch missed (a pattern
# this script reads more narrowly than git does, a failed fetch) is still fetched lazily by the reapply,
# so the working tree is exactly what a checkout of these patterns gives, only slower.
#
# Usage: prefetch-sparse-checkout.sh < PATTERNS_FILE   (path_route: scripts/ci/path-route-sparse-checkout.txt)
# GH_TOKEN, when set, authenticates the fetches.
set -euo pipefail

jobs="${PREFETCH_JOBS:-16}"
patterns="$(cat)"
if [[ -n "${GH_TOKEN:-}" ]]; then
  # Through the environment, not argv: every git child (the lazy fetch of the reapply too) inherits it.
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
  GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
  export GIT_CONFIG_VALUE_0
fi

# A non-cone pattern as a pathspec: /dir/ -> dir/**, /a/*/b -> a/*/b, !/x/**/*.png -> an exclude.
specs=()
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  magic=glob
  if [[ "$line" == !* ]]; then magic=exclude,glob; line="${line#!}"; fi
  line="${line#/}"
  [[ "$line" == */ ]] && line="${line}**"
  specs+=(":($magic)$line")
done <<< "$patterns"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
start=$SECONDS
# Regular files and symlinks only (160000 is a gitlink, which has no blob).
git ls-files -s -- "${specs[@]}" | awk '$1 != "160000" { print $2 }' | sort -u > "$work/oids"
count=$(wc -l < "$work/oids")
if (( count > 0 )); then
  split -n "l/$jobs" "$work/oids" "$work/chunk."
  pids=()
  for chunk in "$work"/chunk.*; do
    [[ -s "$chunk" ]] || continue
    git -c fetch.negotiationAlgorithm=noop fetch -q origin --no-tags --no-write-fetch-head \
      --recurse-submodules=no --filter=blob:none --stdin < "$chunk" & pids+=("$!")
  done
  failed=0
  for pid in "${pids[@]}"; do wait "$pid" || failed=$((failed + 1)); done
  (( failed == 0 )) || echo "::warning::sparse prefetch: $failed of ${#pids[@]} blob fetches failed; the checkout fetches the rest lazily"
fi
echo "sparse prefetch: $count blobs in $jobs fetches, $((SECONDS - start)) s"

printf '%s\n' "$patterns" > "$(git rev-parse --git-path info/sparse-checkout)"
git config core.sparseCheckout true
git config core.sparseCheckoutCone false
git sparse-checkout reapply
echo "sparse checkout: $(git ls-files -t | grep -vc '^S ') files on disk, $((SECONDS - start)) s in all"
