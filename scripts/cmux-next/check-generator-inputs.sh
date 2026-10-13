#!/usr/bin/env bash
# Refuse generated-file repairs from a pull-request tree that is stale on an
# input the generator reads.  Running a generator on the PR head is otherwise
# unsafe: a current base can have added a default that the head's schema does
# not contain, and the generated snapshot would delete that base default.
#
# Usage: check-generator-inputs.sh --base-ref REF [--head-ref REF]
set -euo pipefail

base_ref=""
head_ref=HEAD
while (( $# )); do
  case "$1" in
    --base-ref) base_ref="${2:?missing ref after --base-ref}"; shift 2 ;;
    --head-ref) head_ref="${2:?missing ref after --head-ref}"; shift 2 ;;
    *) echo "usage: $0 --base-ref REF [--head-ref REF]" >&2; exit 2 ;;
  esac
done
[[ -n "$base_ref" ]] || { echo "usage: $0 --base-ref REF [--head-ref REF]" >&2; exit 2; }

# These are the inputs read by defaults_guard.py.  The Swift source directory
# is a pathspec because the guard scans it for Ghostty keybinds and feature
# flags in addition to the checked-in exports.
paths=(
  plans/cmux-next/action-surfaces.json
  schemas/settings/settings-schema.json
  Packages/macOS/CmuxNext/Sources/
  scripts/ci/defaults_guard.py
)

merge_base="$(git merge-base "$base_ref" "$head_ref")" || {
  echo "generator inputs unknown: cannot find a merge base for $base_ref and $head_ref; refusing autofix" >&2
  exit 1
}

mapfile -t base_changed < <(git diff --name-only "$merge_base" "$base_ref" -- "${paths[@]}")
stale=()
for path in "${base_changed[@]}"; do
  # A head that still has the merge-base version has not incorporated the
  # current base's input change. A head that changed the input itself is left
  # to its author: it has an explicit source edit to review and regenerate.
  if git diff --quiet "$merge_base" "$head_ref" -- "$path"; then
    stale+=("$path (base changed after the branch point)")
  fi
done

# A merge commit can hide the same stale tree: #20121 merged the current base
# but resolved settings-schema.json away from the newer base parent. Any merge
# resolution that changes a generator input from the base parent is ambiguous;
# require an explicit follow-up source refresh before autofix runs.
while IFS= read -r merge; do
  [[ -n "$merge" ]] || continue
  read -r _ first second < <(git rev-list --parents -n1 "$merge")
  [[ -n "${second:-}" ]] || continue
  base_parent=""; pr_parent=""
  first_on_base=1; second_on_base=1
  git merge-base --is-ancestor "$first" "$base_ref" && first_on_base=0 || true
  git merge-base --is-ancestor "$second" "$base_ref" && second_on_base=0 || true
  if (( first_on_base == 0 && second_on_base != 0 )); then
    base_parent="$first"; pr_parent="$second"
  elif (( second_on_base == 0 && first_on_base != 0 )); then
    base_parent="$second"; pr_parent="$first"
  elif (( first_on_base == 0 && second_on_base == 0 )); then
    # Both parents can be old base commits. The one nearest the current base
    # is the parent this merge brought in from base.
    first_distance="$(git rev-list --count "$first..$base_ref")"
    second_distance="$(git rev-list --count "$second..$base_ref")"
    if (( first_distance <= second_distance )); then
      base_parent="$first"; pr_parent="$second"
    else
      base_parent="$second"; pr_parent="$first"
    fi
  else
    continue
  fi
  for path in "${paths[@]}"; do
    if ! git diff --quiet "$pr_parent" "$base_parent" -- "$path" && \
       ! git diff --quiet "$base_parent" "$merge" -- "$path" && \
       git diff --quiet "$merge" "$head_ref" -- "$path"; then
      stale+=("$path (merge $merge resolved away from the base parent)")
    fi
  done
done < <(git rev-list --merges "$merge_base..$head_ref")

if (( ${#stale[@]} )); then
  mapfile -t stale < <(printf '%s\n' "${stale[@]}" | sort -u)
  {
    echo "generator inputs are stale; rebase onto $base_ref before running autofix:"
    printf '  %s\n' "${stale[@]}"
    echo "refusing to regenerate generated files from the PR head"
  } >&2
  exit 1
fi
