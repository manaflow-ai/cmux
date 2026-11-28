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
# The key is toolchain, workspace path, package inputs, commit. The toolchain and
# the path make a build unusable when they differ (SwiftPM records absolute
# paths, so a hosted runner's /Users/runner/work never reuses a Blacksmith
# /Users/runner/_work build). The package inputs (manifests and lockfiles) do
# not: SwiftPM re-resolves and rebuilds only what changed. So `<dir>-restore-keys`
# lists, in order: the exact-inputs prefix (newest seed of this package graph),
# the toolchain-and-path prefix (newest seed of any package graph), then the v3
# exact-inputs prefix (seeds saved before v4). v3 put the inputs before the path,
# so after a Package.resolved change nothing restored until a new seed built: on
# 11-28 every head from 10:21Z to 12:55Z built CmuxNext cold, 38 minutes each,
# while the seed waited 63 minutes for a macos-26 runner. r2-cache.sh publishes a
# pointer for every dash-terminated prefix of a saved key, so each line finds the
# newest seed under it. The commit goes last, so a restore by prefix takes the
# newest seed.
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

platform="${RUNNER_OS:-$(uname -s)}-${RUNNER_ARCH:-$(uname -m)}"
near="${platform}-${toolchains:0:16}-${place:0:12}-"
stem="${near}${inputs:0:16}-"
v3_stem="${platform}-${toolchains:0:16}-${inputs:0:16}-${place:0:12}-"
echo "inputs=${inputs:0:16}"
for dir in swift home; do
  echo "${dir}-prefix=cmux-next-fast-v4-${dir}-${stem}"
  echo "${dir}-key=cmux-next-fast-v4-${dir}-${stem}${commit}"
  echo "${dir}-restore-keys<<CMUX_FAST_CACHE_KEYS"
  echo "cmux-next-fast-v4-${dir}-${stem}"
  echo "cmux-next-fast-v4-${dir}-${near}"
  echo "cmux-next-fast-v3-${dir}-${v3_stem}"
  echo "CMUX_FAST_CACHE_KEYS"
done
