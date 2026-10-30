#!/usr/bin/env bash
# cx-x7hwx: may cmux NEXT build <build> be copied to the cmux NIGHTLY-identity
# old feed? Every commit in NIGHTLY_LEGACY_REQUIRED_COMMITS (full SHAs,
# space-separated) must be an ancestor of the build's commit. Example: builds
# with 79dbcd0baf025 (own daemon session per channel) must also carry the
# one-time adopt fix, or a NIGHTLY update opens with an empty session.
#
# Usage: nightly-next-legacy-requirement.sh <owner/repo> <build> [<required sha>...]
#        nightly-next-legacy-requirement.sh --commit <owner/repo> <build sha> [<required sha>...]
#   (--commit: the build's commit is given, as the macOS job reads it from the app.)
#   The build's commit: the "head" of its signed release notes
#   (${NOTES_BASE}/<build>.json, when NOTES_BASE is set and the notes exist),
#   else the head of the nightly-next run that made it (build = run id +
#   two-digit attempt). The macOS job checks the app's own CMUXCommit again.
# Prints one line and exits:
#   0 "ok <build sha>"                   (also when nothing is required)
#   3 "missing <required> <build sha>"   a required commit is not in the build
#   1 "error: ..."                       the check could not run (fail closed)
set -uo pipefail
given=""
if [ "${1:-}" = --commit ]; then
  given="${3:-}"
  set -- "${2:-}" 000 "${@:4}"
  [[ "$given" =~ ^[0-9a-f]{40}$ ]] || { echo "usage: $0 --commit <owner/repo> <build sha> [<required sha>...]" >&2; exit 2; }
fi
repo="${1:-}" build="${2:-}"
shift 2 2>/dev/null || true
if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || ! "$build" =~ ^[0-9]{3,}$ ]]; then
  echo "usage: $0 <owner/repo> <build> [<required sha>...]" >&2
  exit 2
fi
sha="$given"
if [ -z "$sha" ] && [ -n "${NOTES_BASE:-}" ] && notes="$(curl -fsSL --retry 2 "$NOTES_BASE/$build.json" 2>/dev/null)"; then
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
# Whether $1 is in $2's history, from git: "identical", "ahead" or "diverged" (not an
# ancestor), or nothing when git cannot tell. GitHub's compare API builds the whole diff to
# answer, and between a required commit and a nightly-next build days apart it refuses with
# "this diff is temporarily unavailable due to heavy server load" (2026-10-26, run
# 40340830337); ancestry needs only the commit graph, fetched without trees or blobs, and
# costs no API call. NIGHTLY_LEGACY_GIT_URL (default the repository on github.com) names
# the remote; set empty, only the compare API answers.
# Run "$@" for at most $1 seconds (timeout(1) on Linux; perl's alarm on macOS, which has no timeout).
bounded() {
  local seconds="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$seconds" "$@"; else perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"; fi
}
git_ancestry() {
  local url="${NIGHTLY_LEGACY_GIT_URL-https://github.com/$repo.git}" dir rc
  [ "$1" != "$2" ] || { echo identical; return 0; }
  [ -n "$url" ] || return 1
  dir="$(mktemp -d)" || return 1
  # Bounded: a stalled connection falls back to the compare API instead of using up the job.
  if git init -q --bare "$dir" 2>/dev/null &&
    bounded "${NIGHTLY_LEGACY_GIT_SECONDS:-180}" \
      git -C "$dir" -c protocol.version=2 fetch -q --no-tags --filter=tree:0 "$url" "$1" "$2" >/dev/null 2>&1; then
    git -C "$dir" merge-base --is-ancestor "$1" "$2" 2>/dev/null
    rc=$?
  else
    rc=2
  fi
  rm -rf "$dir"
  case "$rc" in 0) echo ahead ;; 1) echo diverged ;; *) return 1 ;; esac
}
for required in "$@"; do
  if [[ ! "$required" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: required commit '$required' is not a full SHA"
    exit 1
  fi
  if status="$(git_ancestry "$required" "$sha")"; then
    :
  elif ! status="$(gh api "repos/$repo/compare/$required...$sha" --jq .status 2>&1)"; then
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
