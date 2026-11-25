#!/usr/bin/env bash
# Print the merge base of BASE and HEAD for the cmux-next media tour
# (.github/workflows/cmux-next-media.yml "Find the merge base").
#
#   media_merge_base.sh BASE_SHA HEAD_SHA
#
# GitHub's compare API answers on the full history. When it fails (the
# installation's API rate limit failed nightly tour 45142205045 here, before any
# build), git answers instead. A shallow clone can hide the real base behind its
# boundary: merge-base then returns an older ancestor, or nothing. So the
# fallback deepens while the answer is missing or is itself a boundary commit.
# Needs GITHUB_REPOSITORY (and GH_TOKEN) for the API, and a checkout whose
# origin has both commits.
set -euo pipefail
base="${1:?base sha}" head="${2:?head sha}"
hex='^[0-9a-f]{40}$'
if [[ "$base" == "$head" ]]; then echo "$base"; exit 0; fi
mb="$(gh api "repos/${GITHUB_REPOSITORY:?}/compare/$base...$head" --jq .merge_base_commit.sha 2>/dev/null || true)"
if [[ "$mb" =~ $hex ]]; then echo "$mb"; exit 0; fi
echo "media_merge_base: GitHub's compare gave no merge base (${mb:-no answer}); asking git" >&2
shallow="$(git rev-parse --git-path shallow)"
depth=100
for _ in 1 2 3 4 5 6; do
  dflag=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && dflag=(--depth="$depth")
  git fetch --no-tags --quiet ${dflag[@]+"${dflag[@]}"} origin "$base" "$head" >&2
  mb="$(git merge-base "$base" "$head" 2>/dev/null || true)"
  if [[ "$mb" =~ $hex ]] && ! { [[ -f "$shallow" ]] && grep -qx "$mb" "$shallow"; }; then
    echo "$mb"; exit 0
  fi
  depth=$(( depth * 4 ))
done
echo "error: no merge base of $base and $head from GitHub or git" >&2
exit 1
