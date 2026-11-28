#!/usr/bin/env bash
# The R2 workspace-delta prefix for the dependency entry a leg actually restored.
#   cargo-delta-prefix.sh <matched key> <target prefix> <delta base> >> "$GITHUB_OUTPUT"
# prints prefix=<delta base><inputs>- when <matched key> is <target prefix><inputs> (16 hex), else prefix=.
# A leg whose own inputs have no dependency entry yet restores another inputs' entry by prefix (a PR
# that changed a Cargo.lock, or feat-cmux-next before its push saved one: the locks change about twice
# an hour). The delta under its own inputs does not exist either, so the leg found none and compiled
# every workspace crate; the delta built on the entry it did restore does exist.
# Why: docs/ci/cmux-next-workflow-notes/2026-11-27-cargo-delta-matched-entry.md
# Test: tests/test_ci_cargo_delta_matched_entry.py
set -euo pipefail
matched="${1-}" target_prefix="${2-}" base="${3-}" prefix=""
if [[ -n "$matched" && -n "$target_prefix" && -n "$base" && "$matched" == "$target_prefix"* ]]; then
  inputs="${matched#"$target_prefix"}"
  if [[ "$inputs" =~ ^[0-9a-f]{16}$ ]]; then prefix="$base$inputs-"; fi
fi
echo "cargo delta: dependency entry ${matched:-none}; delta prefix ${prefix:-none}" >&2
echo "prefix=$prefix"
