#!/usr/bin/env bash
# Seeds SwiftPM's shared binary-artifact cache before an xcodebuild of cmux.xcodeproj on CI.
#
# Every runner slot on an owned Mac (glaeda minis) runs as one user, so all share
# ~/Library/Caches/org.swift.swiftpm/artifacts, which xcodebuild uses even with -clonedSourcePackagesDirPath.
# Two builds that miss one binary artifact (Sparkle, sentry-cocoa's xcframework zips) at once fail with
# "failed downloading '<url>' ... already exists in file system" (cloud-chat-proof run 45797490933,
# cmux10s-mac-mini-glaeda-13, 2026-11-26). scripts/ci/swiftpm_prefetch_binary_artifacts.py seeds the cache from
# a checksum-keyed store under one host lock, so xcodebuild only reads it. The app's package graph is
# Packages/macOS/CmuxNext (cmux.xcodeproj's one local package; the same pins).
#
# On CI (GITHUB_ACTIONS or CI is true) by default; CMUX_RELOAD_SEED_SWIFTPM_ARTIFACTS=1 forces it, =0 skips it.
# Fails soft: xcodebuild downloads whatever the seed missed.
seed_swiftpm_binary_artifacts() {
  local repo_root="$1"
  case "${CMUX_RELOAD_SEED_SWIFTPM_ARTIFACTS:-auto}" in
    0 | no | off) return 0 ;;
    1 | yes | on) ;;
    *) [[ "${GITHUB_ACTIONS:-}" == "true" || "${CI:-}" == "true" ]] || return 0 ;;
  esac
  local seed="$repo_root/scripts/ci/swiftpm_prefetch_binary_artifacts.py"
  [[ -f "$seed" && -d "$repo_root/Packages/macOS/CmuxNext" ]] || return 0
  echo "==> Seeding SwiftPM's shared binary-artifact cache (swiftpm_prefetch_binary_artifacts.py)"
  python3 "$seed" --package-path "$repo_root/Packages/macOS/CmuxNext" || true
}
