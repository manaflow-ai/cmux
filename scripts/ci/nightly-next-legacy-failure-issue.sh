#!/usr/bin/env bash
# cx-x7hwx: print the number of the open "cmux NIGHTLY-identity publication
# failed" issue, or nothing when there is none. Uses GitHub search (an
# open-issue listing returns only one page, and manaflow-ai/cmux has many open
# pull requests), then an exact title match.
# Usage: nightly-next-legacy-failure-issue.sh <owner/repo>
# Exit: 0 found or none (empty output); 1 the search failed.
set -uo pipefail
repo="${1:-}"
if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "usage: $0 <owner/repo>" >&2
  exit 2
fi
title="cmux NIGHTLY-identity publication failed (nightly.yml publish-nightly-identity-legacy)"
if ! rows="$(gh api -X GET search/issues -f q="repo:$repo is:issue is:open in:title \"$title\"" -f per_page=100 \
    --jq '.items[] | "\(.number)\t\(.title)"')"; then
  echo "could not search the issues of $repo" >&2
  exit 1
fi
awk -F '\t' -v t="$title" '$2 == t && $1 ~ /^[0-9]+$/ { print $1; exit }' <<<"$rows"
