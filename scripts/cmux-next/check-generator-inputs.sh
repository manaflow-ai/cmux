#!/usr/bin/env bash
# Check the immutable merge tree used by cmux-next PR autofix.  Generators must
# see the PR merged with the base snapshot supplied for this workflow run; the
# moving base branch is deliberately not consulted.
#
# Usage: check-generator-inputs.sh --base-ref REF --merge-ref REF
set -euo pipefail

base_ref=""
merge_ref=""
while (( $# )); do
  case "$1" in
    --base-ref) base_ref="${2:?missing ref after --base-ref}"; shift 2 ;;
    --merge-ref) merge_ref="${2:?missing ref after --merge-ref}"; shift 2 ;;
    *) echo "usage: $0 --base-ref REF --merge-ref REF" >&2; exit 2 ;;
  esac
done
[[ -n "$base_ref" && -n "$merge_ref" ]] || { echo "usage: $0 --base-ref REF --merge-ref REF" >&2; exit 2; }

# These are the inputs read by defaults_guard.py.  The Swift source directory
# is a pathspec because the guard scans it for Ghostty keybinds and feature
# flags in addition to the checked-in exports.  The docs shortcuts exporter
# (web/scripts/export-docs-shortcuts.ts) reads action-surfaces.json and the
# CmuxNextActions catalogs under Sources/.  Its output
# (web/data/cmux-shortcuts.generated.json) is not listed: it is rewritten from
# these inputs, and a clean merge that equals the PR side of it (the PR's
# autofix already carried the base backstop's change) is not stale.
paths=(
  plans/cmux-next/action-surfaces.json
  schemas/settings/settings-schema.json
  Packages/macOS/CmuxNext/Sources/
  scripts/ci/defaults_guard.py
  web/scripts/export-docs-shortcuts.ts
)

read -r _ first_parent second_parent < <(git rev-list --parents -n1 "$merge_ref")
[[ -n "${second_parent:-}" ]] || {
  echo "generator merge snapshot is not a merge commit; refusing autofix" >&2
  exit 1
}

# GitHub's merge ref uses base, then PR, while a local fixture or another
# merge producer may use the opposite order. Identify the parent containing
# the supplied immutable base snapshot instead of relying on parent position.
if git merge-base --is-ancestor "$base_ref" "$first_parent" && \
   ! git merge-base --is-ancestor "$base_ref" "$second_parent"; then
  base_parent="$first_parent"; pr_parent="$second_parent"
elif git merge-base --is-ancestor "$base_ref" "$second_parent" && \
     ! git merge-base --is-ancestor "$base_ref" "$first_parent"; then
  base_parent="$second_parent"; pr_parent="$first_parent"
else
  first_distance="$(git rev-list --count "$first_parent..$base_ref")"
  second_distance="$(git rev-list --count "$second_parent..$base_ref")"
  if (( first_distance <= second_distance )); then
    base_parent="$first_parent"; pr_parent="$second_parent"
  else
    base_parent="$second_parent"; pr_parent="$first_parent"
  fi
fi

# The event payload gives us the immutable base commit used to make the merge
# snapshot.  Keep the ancestry check so a malformed or stale ref cannot make
# the guard silently approve the wrong tree.
if ! git merge-base --is-ancestor "$base_ref" "$base_parent"; then
  echo "generator merge snapshot does not contain the supplied base snapshot" >&2
  exit 1
fi
merge_base="$(git merge-base "$base_ref" "$pr_parent")"
stale=()
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  # If the base changed a generator input after the PR branch point but the
  # merge tree kept the PR side verbatim, generation would drop a base key.
  if git diff --quiet "$merge_base" "$base_ref" -- "$path"; then
    continue
  fi
  if git diff --quiet "$pr_parent" "$merge_ref" -- "$path"; then
    stale+=("$path (merge snapshot kept the PR side)")
  fi
done < <(git diff --name-only "$merge_base" "$base_ref" -- "${paths[@]}")

if (( ${#stale[@]} )); then
  mapfile -t stale < <(printf '%s\n' "${stale[@]}" | sort -u)
  {
    echo "generator merge snapshot is stale: it kept the PR side for a base input:"
    printf '  %s\n' "${stale[@]}"
    echo "refusing to regenerate generated files"
  } >&2
  exit 1
fi
