#!/usr/bin/env bash
# A merged change's own Rust test, run at its parent (with the change's test files applied) and at the change
# itself: the same measurement before and after (CMUX-571). The test prints its number; the assertion may fail
# before, which is the point.
#   cmux-ci test --setup rust -- bash -c 'scripts/measure/rust-test-at-commits.sh SHA PACKAGE TEST FILTER; echo rc=$?'
# e.g. rust-test-at-commits.sh 4d2ca87a7d91d3119b759ad0910dfa99e6ed315b acpmux durable_agents streaming_restart_gap
set -uo pipefail
sha="${1:?usage: rust-test-at-commits.sh SHA PACKAGE TEST FILTER}" package="${2:?}" test="${3:?}" filter="${4:?}"
root="$(git rev-parse --show-toplevel)"
git -C "$root" fetch -q --no-tags --depth=2 origin "$sha"
parent="$(git -C "$root" rev-parse "$sha^")"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
status=0
for at in "$parent" "$sha"; do
  tree="$scratch/${at:0:12}"
  mkdir -p "$tree"
  git -C "$root" archive "$at" cmux-tui | tar -x -C "$tree"
  if [[ "$at" == "$parent" ]]; then
    # The change's test files (cmux-tui/crates/*/tests), so the parent runs the same test.
    git -C "$root" diff "$parent" "$sha" -- 'cmux-tui/crates/*/tests' | git -C "$tree" apply -p1 || status=$?
  fi
  echo "TEST-AT $at $([[ "$at" == "$parent" ]] && echo before || echo after)"
  (cd "$tree/cmux-tui" && cargo test --locked -p "$package" --test "$test" -- "$filter" --nocapture 2>&1 \
    | grep -vE '^\s*(Compiling|Downloaded|Downloading)') || true
done
exit "$status"
