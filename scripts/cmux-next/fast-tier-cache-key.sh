#!/usr/bin/env bash
# The R2 cache keys of the cmux-next fast tier's build state.
#
#   fast-tier-cache-key.sh [ROOT]
#
# Prints `<dir>-prefix=...` and `<dir>-key=...` lines for $GITHUB_OUTPUT, for
# each directory the Mac fast tier builds into (scripts/ci/r2-cache.sh archives
# one directory per key): swift (Packages/macOS/CmuxNext/.build) and home
# (Packages/Shared/CmuxHomeRender/.build). The cargo entries run on Linux
# (cmux-next.yml fast-tier-cargo) with their own cargo cache.
#
# The seed workflow (cmux-next-fast-tier-seed.yml) saves both under one
# commit on feat-cmux-next. The fast tier (cmux-next.yml) restores swift by
# prefix, then home by the exact key of the seed commit it got, so both
# directories come from one seed and the input-time manifest in the swift
# directory (e2e_warm_derived_data.py) describes them. Both call this
# script, so a reader can never ask for a key no writer makes.
#
# The prefix holds everything that makes a build unusable when it differs: the
# Xcode toolchain, the package manifests and lockfiles, and the workspace path
# (SwiftPM records absolute paths, so a hosted runner's /Users/runner/work never
# reuses a Blacksmith /Users/runner/_work build). The commit goes last, so a
# restore by prefix takes the newest seed. v3 dropped the cargo directory and
# the Rust, Cargo and ghostty-next inputs that only it needed.
set -euo pipefail

root="${1:-.}"
cd "$root"

sha256() { shasum -a 256 | awk '{print $1}'; }

xcode="${CMUX_FAST_CACHE_XCODE_VERSION:-$(xcodebuild -version)}"
workspace="${CMUX_FAST_CACHE_WORKSPACE:-${GITHUB_WORKSPACE:-$PWD}}"
commit="${CMUX_FAST_CACHE_COMMIT:-${GITHUB_SHA:-$(git rev-parse HEAD)}}"

# Index entries (mode, blob, path) of the manifests and lockfiles: stable on
# any checkout, whatever the files' times or line endings on disk.
inputs="$(git ls-files -s -- ':(glob)**/Package.swift' ':(glob)**/Package.resolved' scripts/ci/swiftpm-cache-layout | sha256)"
toolchains="$(printf '%s\n' "$xcode" | sha256)"
place="$(printf '%s' "$workspace" | sha256)"

stem="${RUNNER_OS:-$(uname -s)}-${RUNNER_ARCH:-$(uname -m)}-${toolchains:0:16}-${inputs:0:16}-${place:0:12}-"
for dir in swift home; do
  echo "${dir}-prefix=cmux-next-fast-v3-${dir}-${stem}"
  echo "${dir}-key=cmux-next-fast-v3-${dir}-${stem}${commit}"
done
