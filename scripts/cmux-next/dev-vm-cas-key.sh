#!/usr/bin/env bash
# The DEV Release compile's Xcode compilation cache on a VM that keeps nothing between jobs
# (Blacksmith macOS): where it lives and the actions/cache key it rides under, for $GITHUB_OUTPUT.
#
# A mini keeps its cache on disk (compile-dev-release.sh, host mode). A Blacksmith VM starts
# empty, so the workflow restores the cache through Blacksmith's own actions/cache, served next to
# the runner, before compile-dev-release.sh runs with CMUX_NEXT_DEV_VM_CACHE=1, and saves it after,
# as classic's nightly does with its compilation cache (Leo, 2026-10-26: "just give them the
# cache. we have done this before with classic").
#
# The cache's own keys hold the absolute source and DerivedData paths. On Blacksmith both are the
# same on every VM (the checkout under /Users/runner/_work, DerivedData under RUNNER_TEMP:
# release-derived-data-path.sh), so one VM's cache replays on the next. This key holds those paths
# and the toolchain, so a different path or Xcode is a different cache line, never a wrong replay;
# within a line Xcode's per-job keys decide what replays.
#
# Prints path= (the CompilationCache.noindex directory) and prefix= (the key without the commit;
# the workflow appends the commit to save, and restores the newest entry under the prefix).
# Usage: dev-vm-cas-key.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
workspace="$(cd "$here/../.." && pwd -P)"
derived_data="$("$here/release-derived-data-path.sh" dev-daily-release Release)"
mkdir -p "$derived_data"
derived_data="$(cd "$derived_data" && pwd -P)"
fields="$(printf '%s\n' \
  "recipe=dev-vm-cas-v1" \
  "xcode=$(xcodebuild -version | tr '\n' ' ')" \
  "developer_dir=${DEVELOPER_DIR:-$(xcode-select -p)}" \
  "sdk=$(xcrun --sdk macosx --show-sdk-version) $(xcrun --sdk macosx --show-sdk-build-version)" \
  "arch=$(uname -m)" \
  "swift_mode=${CMUX_NEXT_SWIFT_COMPILATION_MODE:-auto}" \
  "build_root=$workspace" \
  "derived_data=$derived_data")"
digest="$(printf '%s' "$fields" | shasum -a 256 | cut -c1-24)"
printf 'path=%s\n' "$derived_data/CompilationCache.noindex"
printf 'prefix=cmux-next-dev-vm-cas-%s-%s-\n' "$(uname -m)" "$digest"
