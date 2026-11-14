#!/usr/bin/env bash
# A merged change's own Rust test, run at its parent (with the change's test files taken from it) and at the
# change itself: the same measurement before and after (CMUX-571). The test prints its number; the assertion may
# fail before, which is the point.
#   cmux-ci test --setup rust -- bash -c 'scripts/measure/rust-test-at-commits.sh SHA PACKAGE TEST FILTER; echo rc=$?'
# e.g. rust-test-at-commits.sh 4d2ca87a7d91d3119b759ad0910dfa99e6ed315b acpmux durable_agents streaming_restart_gap
set -uo pipefail
sha="${1:?usage: rust-test-at-commits.sh SHA PACKAGE TEST FILTER}" package="${2:?}" test="${3:?}" filter="${4:?}"
root="$(git rev-parse --show-toplevel)"
git -C "$root" fetch -q --no-tags --depth=2 origin "$sha"
parent="$(git -C "$root" rev-parse "$sha^")"
tests=()
while IFS= read -r path; do tests+=("$path"); done < <(git -C "$root" diff --name-only "$parent" "$sha" | grep -E '^cmux-tui/crates/[^/]+/tests/')
scratch="$(mktemp -d)"
trees=()
cleanup() {
  for tree in "${trees[@]}"; do git -C "$root" worktree remove --force "$tree" >/dev/null 2>&1; done
  rm -rf "$scratch"
}
trap cleanup EXIT
for at in "$parent" "$sha"; do
  tree="$scratch/${at:0:12}"
  git -C "$root" worktree add -q --detach "$tree" "$at" && trees+=("$tree")
  # The parent runs the change's own test files.
  [[ "$at" == "$parent" && ${#tests[@]} -gt 0 ]] && git -C "$tree" checkout -q "$sha" -- "${tests[@]}"
  echo "TEST-AT $at $([[ "$at" == "$parent" ]] && echo before || echo after) (${#tests[@]} test files from $sha)"
  (cd "$tree/cmux-tui" && cargo test --locked -p "$package" --test "$test" -- "$filter" --nocapture 2>&1 \
    | grep -vE '^\s*(Compiling|Downloaded|Downloading)') || true
done
