#!/usr/bin/env bash
# The R2 keys of the App Store shelf check's cargo build, printed as GITHUB_OUTPUT lines. The seed
# (.github/workflows/app-store-shelf-cargo-seed.yml, feat-cmux-next pushes) saves under them; the shelf jobs
# (cmux-next-guards.yml app-store-shelf-pr, app-store-shelf.yml shelf) restore them before
# scripts/ci/app-store-shelf-check.sh, so all three call this one script.
#
# Why: every shelf run that reached its inputs compiled cmux-tui's `it` test binary cold, 635 crates, with no
# cargo cache: 5 to 12 min of a 5 to 13 min job, about 50 of 257 shelf jobs an hour (2026-11-27).
#
# The key covers everything that changes the compiled dependencies: the lockfiles, the toolchain, the profile
# variables the check builds with (set here exactly as app-store-shelf-check.sh sets them) and the workspace
# path, which cargo bakes into its fingerprints. A restore replaces cmux-tui/target whole
# (scripts/ci/r2-cache.sh), so a workspace that already holds a build (a reused self-hosted workspace) or a
# runner-wide CARGO_TARGET_DIR prints no target key and keeps what it has. `--seed` (the seed job, which saves
# whatever it builds) always prints it.
set -euo pipefail
seed=false
[[ "${1:-}" == --seed ]] && seed=true
export CARGO_PROFILE_DEV_DEBUG="${CARGO_PROFILE_DEV_DEBUG:-0}" CARGO_PROFILE_TEST_DEBUG="${CARGO_PROFILE_TEST_DEBUG:-0}"
export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"
inputs="$( {
  git ls-files -z -- 'cmux-tui/Cargo.lock' 'cmux-tui/**/Cargo.lock' 'cmux-tui/rust-toolchain.toml' | xargs -0 sha256sum
  (cd cmux-tui && rustc -Vv && cargo -V)
  env | grep -E '^(CARGO_PROFILE_[A-Z_]+|CARGO_INCREMENTAL)=' | LC_ALL=C sort || true
} | sha256sum | cut -c1-16)"
workspace="$(printf '%s' "${GITHUB_WORKSPACE:-$PWD}" | sha256sum | cut -c1-8)"
prefix="app-store-shelf-cargo-v1-$workspace-"
if [[ "$seed" != true && -n "${CARGO_TARGET_DIR:-}" ]]; then
  echo "app-store-shelf-cargo-key: CARGO_TARGET_DIR is set ($CARGO_TARGET_DIR); no target restore" >&2
elif [[ "$seed" != true && -d cmux-tui/target/debug/deps ]]; then
  echo "app-store-shelf-cargo-key: cmux-tui/target already holds a build; no target restore" >&2
else
  echo "target-prefix=$prefix"
  echo "target-key=$prefix$inputs"
fi
echo "registry-prefix=app-store-shelf-cargo-registry-v1-"
echo "registry-key=app-store-shelf-cargo-registry-v1-$inputs"
echo "registry=${CARGO_HOME:-$HOME/.cargo}/registry"
