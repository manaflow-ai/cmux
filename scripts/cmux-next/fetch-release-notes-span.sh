#!/usr/bin/env bash
# Fetch what scripts/cmux-next/release-notes.py reads, and nothing else: the
# commits from the published <tag> to <head_sha>, plus the files at <head_sha>.
# A full fetch of every branch and tag timed out the sign-release-notes job
# (nightly-next run 37526646874). This fetch is blobless (git fetches the few
# highlight files on demand) and starts at a bounded depth, deepened until the
# tag and the head share history; past the bound it unshallows the head only.
#
# Usage: fetch-release-notes-span.sh <remote> <head_sha> <tag>
# Environment: RELEASE_NOTES_FETCH_DEPTH (default 300),
#              RELEASE_NOTES_DEEPEN_STEP (default 1000), RELEASE_NOTES_DEEPEN_ROUNDS (default 4)
set -euo pipefail
[[ $# -eq 3 ]] || { echo "usage: $0 <remote> <head_sha> <tag>" >&2; exit 64; }
remote="$1" head="$2" tag="$3"
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "error: head must be a full commit sha: $head" >&2; exit 64; }
depth="${RELEASE_NOTES_FETCH_DEPTH:-300}"
step="${RELEASE_NOTES_DEEPEN_STEP:-1000}"
rounds="${RELEASE_NOTES_DEEPEN_ROUNDS:-4}"

refspecs=("$head")
if git ls-remote --exit-code --tags "$remote" "refs/tags/$tag" >/dev/null 2>&1; then
  refspecs+=("+refs/tags/$tag:refs/tags/$tag")
else
  echo "no $tag tag on $remote; the notes cover the head's fetched history" >&2
  tag=""
fi
git fetch --no-tags --filter=blob:none --depth="$depth" "$remote" "${refspecs[@]}"
[[ -n "$tag" ]] || exit 0

since="refs/tags/$tag^{commit}"
for ((i = 0; i < rounds; i++)); do
  git merge-base "$since" "$head" >/dev/null 2>&1 && exit 0
  git fetch --no-tags --filter=blob:none --deepen="$step" "$remote" "${refspecs[@]}"
done
git merge-base "$since" "$head" >/dev/null 2>&1 && exit 0
echo "$tag and $head share no history within the bounded depth; unshallowing the head" >&2
git fetch --no-tags --filter=blob:none --unshallow "$remote" "${refspecs[@]}"
