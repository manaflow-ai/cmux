#!/usr/bin/env bash
# cx-x7hwx: may cmux NEXT build <build> be copied to the cmux NIGHTLY-identity
# old feed? Every commit in NIGHTLY_LEGACY_REQUIRED_COMMITS (full SHAs,
# space-separated) must be an ancestor of the build's commit. Example: builds
# with 79dbcd0baf025 (own daemon session per channel) must also carry the
# one-time adopt fix, or a NIGHTLY update opens with an empty session.
#
# Usage: nightly-next-legacy-requirement.sh <owner/repo> <build> [<required sha>...]
#   The build's commit: the "head" of its signed release notes
#   (${NOTES_BASE}/<build>.json, when NOTES_BASE is set and the notes exist),
#   else the head of the nightly-next run that made it (build = run id +
#   two-digit attempt). The macOS job checks the app's own CMUXCommit again.
# Prints one line and exits:
#   0 "ok <build sha>"                   (also when nothing is required)
#   3 "missing <required> <build sha>"   a required commit is not in the build
#   1 "error: ..."                       the check could not run (fail closed)
set -uo pipefail
repo="${1:-}" build="${2:-}"
shift 2 2>/dev/null || true
if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || ! "$build" =~ ^[0-9]{3,}$ ]]; then
  echo "usage: $0 <owner/repo> <build> [<required sha>...]" >&2
  exit 2
fi
sha=""
if [ -n "${NOTES_BASE:-}" ] && notes="$(curl -fsSL --retry 2 "$NOTES_BASE/$build.json" 2>/dev/null)"; then
  sha="$(python3 -I -c 'import json, sys; d = json.loads(sys.argv[1]); print(d["head"] if str(d.get("build")) == sys.argv[2] else "")' "$notes" "$build" 2>/dev/null || true)"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || sha=""
fi
if [ -z "$sha" ]; then
  run_id="${build%??}"
  if ! head="$(gh api "repos/$repo/actions/runs/$run_id" --jq '"\(.head_sha) \(.head_branch) \(.path)"' 2>&1)"; then
    echo "error: could not read run $run_id of build $build (${head//$'\n'/ })"
    exit 1
  fi
  read -r sha branch path <<<"$head"
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ || "$branch" != nightly-next || "$path" != .github/workflows/nightly.yml ]]; then
    echo "error: run $run_id of build $build is not a nightly-next nightly.yml run ($head)"
    exit 1
  fi
fi
for required in "$@"; do
  if [[ ! "$required" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: required commit '$required' is not a full SHA"
    exit 1
  fi
  if ! status="$(gh api "repos/$repo/compare/$required...$sha" --jq .status 2>&1)"; then
    echo "error: could not compare $required with $sha (${status//$'\n'/ })"
    exit 1
  fi
  case "$status" in
    ahead|identical) ;;
    behind|diverged) echo "missing $required $sha"; exit 3 ;;
    *) echo "error: unexpected compare status '$status' for $required...$sha"; exit 1 ;;
  esac
done
echo "ok $sha"
