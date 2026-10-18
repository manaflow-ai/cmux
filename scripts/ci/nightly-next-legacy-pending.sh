#!/usr/bin/env bash
# Find and download the newest pending cmux NIGHTLY-identity submission.
#
# GitHub Actions artifact discovery is a safety boundary: if the API cannot
# prove that no pending submission exists, the caller must not submit the same
# build again.  Exit non-zero for an API or artifact-read error; print empty
# outputs only after a successful search finds no candidate.
#
# Usage: nightly-next-legacy-pending.sh <owner/repo> <output-directory>
# Outputs pending_meta=<path> and pending_run=<run id> on success.
set -euo pipefail

repo="${1:-}"
output="${2:-}"
if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || -z "$output" ]]; then
  echo "usage: $0 <owner/repo> <output-directory>" >&2
  exit 2
fi

mkdir -p "$output"
rm -rf "$output"/*

if ! candidates="$(gh api "repos/$repo/actions/artifacts?name=cmux-nightly-identity-pending-meta&per_page=20" \
    --jq '[.artifacts[] | select(.expired == false and .workflow_run.head_branch == "nightly-next" and .workflow_run.head_repository_id == .workflow_run.repository_id)] | sort_by(.created_at) | reverse | .[] | "\(.id) \(.workflow_run.id)"')"; then
  echo "could not list pending cmux NIGHTLY-identity artifacts" >&2
  exit 1
fi

while read -r meta_id meta_run; do
  [ -n "${meta_id:-}" ] || continue
  [[ "$meta_id" =~ ^[0-9]+$ && "$meta_run" =~ ^[0-9]+$ ]] || {
    echo "malformed pending artifact candidate: $meta_id $meta_run" >&2
    exit 1
  }

  if ! origin="$(gh api "repos/$repo/actions/runs/$meta_run" --jq '"\(.path) \(.event) \(.head_branch) \(.head_repository.full_name)"')"; then
    echo "could not validate pending artifact run $meta_run" >&2
    exit 1
  fi
  case "$origin" in
    ".github/workflows/nightly.yml push nightly-next $repo"|".github/workflows/nightly.yml workflow_dispatch nightly-next $repo") ;;
    *)
      echo "skipping pending artifact $meta_id of unrelated run $meta_run ($origin)" >&2
      continue
      ;;
  esac

  zip_path="$output/meta.zip"
  if ! gh api "repos/$repo/actions/artifacts/$meta_id/zip" > "$zip_path"; then
    echo "could not download pending artifact $meta_id" >&2
    exit 1
  fi
  if ! unzip -o -q "$zip_path" -d "$output" || [ ! -f "$output/pending.json" ]; then
    echo "pending artifact $meta_id has no pending.json" >&2
    exit 1
  fi
  # An accepted submission's metadata may be re-stored by a later run and
  # names the original bundle run. If that bundle is confirmed gone, skip this
  # stale candidate; an API error must fail closed so it cannot cause a
  # duplicate Apple submission.
  bundle_run="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("bundle_run") or sys.argv[2])' "$output/pending.json" "$meta_run")"
  if ! bundles="$(gh api "repos/$repo/actions/runs/$bundle_run/artifacts?name=cmux-nightly-identity-pending-bundle" \
      --jq '[.artifacts[] | select(.expired == false)] | length')"; then
    echo "could not validate pending bundle for run $bundle_run" >&2
    exit 1
  fi
  if [ "$bundles" = 0 ]; then
    echo "skipping pending artifact $meta_id: bundle of run $bundle_run is gone" >&2
    rm -f "$output/pending.json" "$output/meta.zip"
    continue
  fi
  printf 'pending_meta=%s\n' "$output/pending.json"
  printf 'pending_run=%s\n' "$meta_run"
  exit 0
done <<< "$candidates"

printf 'pending_meta=\n'
printf 'pending_run=\n'
