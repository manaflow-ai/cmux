#!/usr/bin/env bash
#
# Generate TestFlight "What to Test" notes from the iOS-affecting commits in
# <base-ref>..HEAD, so every beta build's notes reflect what actually changed
# since the previous beta instead of a hand-maintained changelog top entry.
#
#   internal (default): terse, dev-facing bullets, keeps the PR number.
#   external:           cleaned user-facing bullets (no PR numbers, no
#                       conventional prefix), suitable for the external beta lane.
#
# Output is the bullet list only (no "### Internal" heading), suitable to pass to
# `set-testflight-notes.sh --notes "$(...)"`. An empty or unreachable range emits
# a deterministic fallback line and exits 0, so the non-fatal notes step in
# upload-testflight.sh never breaks an upload.
#
# Usage:
#   ios/scripts/generate-testflight-notes.sh <base-ref> [--audience internal|external]
#
# Portable to macOS bash 3.2 + BSD sed (runs on the fleet/CI macOS runners): no
# mapfile, no GNU-only sed escapes.

set -euo pipefail

usage() { sed -n '3,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

AUDIENCE="internal"
BASE=""
MAX="${CMUX_NOTES_MAX:-20}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --audience) AUDIENCE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "error: unknown option $1" >&2; exit 2 ;;
    *) BASE="$1"; shift ;;
  esac
done

case "$AUDIENCE" in
  internal|external) ;;
  *) echo "error: --audience must be internal or external" >&2; exit 2 ;;
esac

fallback() {
  echo "- Latest main; no notable iOS changes detected since the previous build."
}

# No base, or a base not reachable in this checkout (shallow clone, unknown SHA):
# fall back rather than fail. Notes are non-fatal; a missing range must not break
# the upload.
if [[ -z "$BASE" ]] || ! git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null; then
  fallback
  exit 0
fi

# Base must be an ancestor of HEAD, or "BASE..HEAD" is not a meaningful "since the
# previous beta" range (e.g. the caller fed a SHA from an unrelated branch). Fail
# closed to the fallback line rather than emit notes for a bogus commit range.
if ! git merge-base --is-ancestor "$BASE" HEAD 2>/dev/null; then
  fallback
  exit 0
fi

# iOS-affecting paths: mirror the push-trigger filter in ios-testflight.yml so the
# notes only mention changes that could be in this build.
PATHS="ios Packages/iOS Packages/Shared Sources/Mobile vendor/stack-auth-swift-sdk-prerelease scripts/ghosttykit-checksums.txt"

# First-line subjects of non-merge commits in range touching those paths. Squash
# merges carry the PR title + "(#N)" as the subject, which is exactly what we want.
emitted=0
# Newline-delimited set of subjects already emitted. A commit subject is one git
# log line, so it never contains a newline; membership is an exact fixed-string
# line match (grep -Fx), which avoids both glob interpretation and a separator
# collision (an earlier `|`-delimited scheme dropped distinct subjects that
# happened to contain `|`, e.g. "feat: support A|B mode").
seen=""

while IFS= read -r subject; do
  [[ -n "$subject" ]] || continue

  # Drop noise that is not tester-relevant.
  case "$subject" in
    chore:*|chore\(*|ci:*|ci\(*|build:*|build\(*|test:*|test\(*|docs:*|docs\(*) continue ;;
    Merge\ *|"Bump version"*|*"bump version"*|*"version bump"*) continue ;;
  esac

  # De-dupe identical subjects, preserving first-seen order.
  if printf '%s\n' "$seen" | grep -Fxq -- "$subject"; then continue; fi
  seen="${seen}${subject}
"

  if [[ "$emitted" -ge "$MAX" ]]; then
    echo "- ...and more (see the commit log)"
    break
  fi

  if [[ "$AUDIENCE" == "external" ]]; then
    # Clean for founders/external beta: strip "(#N)" / "#N", and a leading
    # conventional prefix like "ios:" / "fix(mobile):".
    clean="$(printf '%s' "$subject" \
      | sed -E 's/ *\(#[0-9]+\)//g; s/ +#[0-9]+//g' \
      | sed -E 's/^[a-z]+(\([^)]*\))?(!)?: *//')"
    [[ -n "$clean" ]] || clean="$subject"
    echo "- ${clean}"
  else
    echo "- ${subject}"
  fi
  emitted=$((emitted + 1))
done < <(git log --no-merges --format='%s' "${BASE}..HEAD" -- $PATHS 2>/dev/null || true)

if [[ "$emitted" -eq 0 ]]; then
  fallback
fi
