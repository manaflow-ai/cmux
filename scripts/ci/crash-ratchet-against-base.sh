#!/usr/bin/env bash
# The crash ratchet's CI step (.github/workflows/cmux-next-guards.yml, job crash-ratchet):
# scripts/ci/crash_ratchet_compare.py on the checked-out change and on its base's exported tree.
# It also judges the change's crash-safety-baseline.json against the base's copy (the baseline
# may only go down; a recorded waiver is annotated).
#
#   EVENT_NAME  the GitHub event (pull_request, or push)
#   BEFORE      a push's previous tip (github.event.before); unused for pull requests
#   RUNNER_TEMP scratch folder for the base's exported tree (default: a new temp folder)
#
# Run from the root of the checked-out change. A pull request's checkout is its merge commit,
# so its base is HEAD^1; a push's base is BEFORE (fetched when the checkout lacks it).
# tests/test_crash_ratchet_compare.py runs this script against throwaway repositories.
set -eo pipefail

temp="${RUNNER_TEMP:-$(mktemp -d)}"
base_ref=""
if [[ "$EVENT_NAME" == pull_request ]]; then
  base_ref=HEAD^1
elif [[ "$BEFORE" =~ ^[0-9a-f]{40}$ && ! "$BEFORE" =~ ^0+$ ]] \
  && { git cat-file -e "$BEFORE^{commit}" 2>/dev/null || git fetch --no-tags --depth=1 origin "$BEFORE"; }; then
  base_ref="$BEFORE"
fi
if [[ -z "$base_ref" ]]; then
  echo "::warning::no previous tip to compare with; running the plain ratchet"
  exec python3 scripts/cmux-next/crash_ratchet.py
fi
base_dir="$temp/crash-ratchet-base"
mkdir -p "$base_dir"
paths=()
for p in Packages cmux-tui/crates scripts/cmux-next; do
  if git cat-file -e "$base_ref:$p" 2>/dev/null; then paths+=("$p"); fi
done
if [[ ${#paths[@]} -gt 0 ]]; then
  git archive --format=tar "$base_ref" "${paths[@]}" | tar -x -C "$base_dir"
fi
python3 scripts/ci/crash_ratchet_compare.py --script scripts/cmux-next/crash_ratchet.py \
  --head "$PWD" --base "$base_dir"
