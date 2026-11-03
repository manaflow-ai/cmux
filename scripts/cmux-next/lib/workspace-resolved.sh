# shellcheck shell=bash
# Sourced by check-cmux-scheme-compile.sh. Keeps a reused self-hosted
# workspace clean after xcodebuild so the next job builds incrementally.
#
# xcodebuild rewrites the app workspace's Package.resolved whenever the
# committed copy is stale against the package manifests (from 2026-10-09 to
# 2026-10-24 it lacked swift-atomics, which CmuxNextCompat had added). The
# glaeda job-start hook resets a workspace whose tracked files differ from
# HEAD, and the checkout after it rewrites every file. Every Swift module's
# inputs then look new, so the runner's kept DerivedData rebuilt all 129
# modules on every DEV Release compile (518-560 s for a one-file merge).
# Putting the committed copy back keeps the workspace clean: the checkout then
# rewrites only the files the merge changed and xcodebuild recompiles only
# the modules they affect.
#
# Never fails the build: a missing repository, file or git error is a warning.
#
# Usage: cmux_next_restore_workspace_resolved <repo root>
cmux_next_restore_workspace_resolved() {
  local root=$1
  local rel=cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  git -C "$root" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 || return 0
  git -C "$root" diff --quiet -- "$rel" 2>/dev/null && return 0
  echo "::warning file=$rel::xcodebuild rewrote the committed Package.resolved, so it is stale against the package manifests. Restored the committed copy to keep this runner's workspace (and its incremental build) intact; commit the resolved file to stop the re-resolve."
  git -C "$root" diff --stat -- "$rel" 2>/dev/null || true
  git -C "$root" checkout -- "$rel" 2>/dev/null \
    || echo "warning: could not restore $rel; the next job on this runner rebuilds from a reset workspace" >&2
  return 0
}
