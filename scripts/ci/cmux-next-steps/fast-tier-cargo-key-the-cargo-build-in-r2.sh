#!/usr/bin/env bash
# cmux-next.yml fast-tier-cargo: "Key the cargo build in R2".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
inputs="$( { git ls-files -z -- 'cmux-tui/Cargo.lock' 'cmux-tui/**/Cargo.lock' 'cmux-tui/rust-toolchain.toml' \
  | xargs -0 sha256sum; rustc -Vv; cargo -V; } | sha256sum | cut -c1-16)"
workspace="$(printf '%s' "$GITHUB_WORKSPACE" | sha256sum | cut -c1-8)"
prefix="cmux-next-fast-tier-cargo-v2-$workspace-"
{
  echo "target-prefix=$prefix"
  echo "target-key=$prefix$inputs"
  echo "registry-prefix=cmux-next-fast-tier-cargo-registry-v1-"
  echo "registry-key=cmux-next-fast-tier-cargo-registry-v1-$inputs"
  echo "registry=${CARGO_HOME:-$HOME/.cargo}/registry"
  # The workspace delta on top of that entry, one per feat-cmux-next commit (scripts/ci/cargo-target-delta.sh).
  echo "ws-prefix=cmux-next-fast-tier-cargo-ws-v1-$workspace-$inputs-"
  echo "ws-key=cmux-next-fast-tier-cargo-ws-v1-$workspace-$inputs-$GITHUB_SHA"
} >> "$GITHUB_OUTPUT"
