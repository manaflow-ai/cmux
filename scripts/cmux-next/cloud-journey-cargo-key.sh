#!/usr/bin/env bash
# The R2 keys of cloud-journey-pr.yml's cargo build, printed as GITHUB_OUTPUT lines. The `seed` job (feat-cmux-next
# pushes) saves under them and the `journey` job (pull requests) restores them, so both call this one script.
# The key covers everything that changes the compiled dependencies: the lockfiles, the toolchain, the profile
# variables the workflow sets (CARGO_PROFILE_*, CARGO_INCREMENTAL) and the workspace path, which cargo bakes
# into its fingerprints. Why: docs/ci/cmux-next-workflow-notes.md#note-cloud-journey-pr-wall
set -euo pipefail
inputs="$( {
  git ls-files -z -- 'cmux-tui/Cargo.lock' 'cmux-tui/**/Cargo.lock' 'cmux-tui/rust-toolchain.toml' | xargs -0 sha256sum
  (cd cmux-tui && rustc -Vv && cargo -V)
  env | grep -E '^(CARGO_PROFILE_[A-Z_]+|CARGO_INCREMENTAL)=' | LC_ALL=C sort || true
} | sha256sum | cut -c1-16)"
workspace="$(printf '%s' "$GITHUB_WORKSPACE" | sha256sum | cut -c1-8)"
prefix="cloud-journey-pr-cargo-v1-$workspace-"
echo "target-prefix=$prefix"
echo "target-key=$prefix$inputs"
echo "registry-prefix=cloud-journey-pr-cargo-registry-v1-"
echo "registry-key=cloud-journey-pr-cargo-registry-v1-$inputs"
echo "registry=${CARGO_HOME:-$HOME/.cargo}/registry"
