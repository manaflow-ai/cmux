#!/usr/bin/env bash
# The GitHub Actions cache key of the cmux-next fast tier's build state.
#
#   fast-tier-cache-key.sh [ROOT]
#
# Prints `prefix=...` and `key=...` lines for $GITHUB_OUTPUT. One entry holds
# both Swift package builds and the cmux-tui cargo target, so every restored
# directory comes from the same seed commit and one input-time manifest
# (e2e_warm_derived_data.py) describes all of them.
#
# The fast-tier job (cmux-next.yml) restores by `prefix`; the seed workflow
# (cmux-next-fast-tier-seed.yml) saves under `key` on feat-cmux-next. Both call
# this script, so a reader can never ask for a key no writer makes.
#
# The prefix holds everything that makes a build unusable when it differs: the
# Xcode and Rust toolchains, the dependency lockfiles and manifests, the
# ghostty-next commit libghostty-vt builds from, and the workspace path (SwiftPM
# and cargo record absolute paths, so a hosted runner's /Users/runner/work never
# reuses a Blacksmith /Users/runner/_work build). The commit goes last, so a
# restore by prefix takes the newest seed.
set -euo pipefail

root="${1:-.}"
cd "$root"

sha256() { shasum -a 256 | awk '{print $1}'; }

xcode="${CMUX_FAST_CACHE_XCODE_VERSION:-$(xcodebuild -version)}"
rust="${CMUX_FAST_CACHE_RUST_VERSION:-$(rustc -vV)}"
workspace="${CMUX_FAST_CACHE_WORKSPACE:-${GITHUB_WORKSPACE:-$PWD}}"
commit="${CMUX_FAST_CACHE_COMMIT:-${GITHUB_SHA:-$(git rev-parse HEAD)}}"

# Index entries (mode, blob, path) of the manifests and lockfiles: stable on
# any checkout, whatever the files' times or line endings on disk.
swift_inputs="$(git ls-files -s -- ':(glob)**/Package.swift' ':(glob)**/Package.resolved' scripts/ci/swiftpm-cache-layout | sha256)"
cargo_inputs="$(git ls-files -s -- cmux-tui/Cargo.lock cmux-tui/Cargo.toml cmux-tui/rust-toolchain.toml | sha256)"
ghostty="$(git rev-parse HEAD:ghostty-next)"

toolchains="$(printf '%s\n%s\n' "$xcode" "$rust" | sha256)"
inputs="$(printf '%s\n%s\n%s\n' "$swift_inputs" "$cargo_inputs" "$ghostty" | sha256)"
place="$(printf '%s' "$workspace" | sha256)"

prefix="cmux-next-fast-v2-${RUNNER_OS:-$(uname -s)}-${RUNNER_ARCH:-$(uname -m)}-${toolchains:0:16}-${inputs:0:16}-${place:0:12}-"
echo "prefix=$prefix"
echo "key=${prefix}${commit}"
