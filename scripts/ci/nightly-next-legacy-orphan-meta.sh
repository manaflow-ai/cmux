#!/usr/bin/env bash
# cx-x7hwx: retire a cmux NIGHTLY-identity pending metadata artifact only when
# its run CONFIRMS that the bundle is gone (no unexpired
# cmux-nightly-identity-pending-bundle). Any API error (rate limit, 5xx,
# timeout) keeps the metadata, so a valid pending submission is never thrown
# away by a transient failure.
# Usage: nightly-next-legacy-orphan-meta.sh <owner/repo> <meta run id> [<bundle run id>]
# (the bundle run defaults to the meta run; an accepted submission's metadata
# is re-stored by a later run and points at the original bundle run)
# Prints "retired" or "kept: <reason>"; exits 0 either way, 2 on bad usage.
set -uo pipefail
repo="${1:-}" run="${2:-}" bundle_run="${3:-${2:-}}"
if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || ! "$run" =~ ^[0-9]+$ || ! "$bundle_run" =~ ^[0-9]+$ ]]; then
  echo "usage: $0 <owner/repo> <meta run id> [<bundle run id>]" >&2
  exit 2
fi
if ! bundles="$(gh api "repos/$repo/actions/runs/$bundle_run/artifacts?name=cmux-nightly-identity-pending-bundle" \
    --jq '[.artifacts[] | select(.expired == false)] | length' 2>&1)"; then
  echo "kept: could not read the bundle artifacts of run $bundle_run (${bundles//$'\n'/ })"
  exit 0
fi
if [ "$bundles" != 0 ]; then
  echo "kept: run $bundle_run still has $bundles bundle artifact(s)"
  exit 0
fi
if ! ids="$(gh api "repos/$repo/actions/runs/$run/artifacts?name=cmux-nightly-identity-pending-meta" --jq '.artifacts[].id' 2>&1)"; then
  echo "kept: could not list the metadata of run $run (${ids//$'\n'/ })"
  exit 0
fi
for id in $ids; do
  [[ "$id" =~ ^[0-9]+$ ]] || continue
  gh api -X DELETE "repos/$repo/actions/artifacts/$id" >/dev/null 2>&1 || { echo "kept: could not delete metadata $id of run $run"; exit 0; }
done
echo "retired"
