#!/usr/bin/env bash
# Print the Cargo target directory cmux-tui's macOS job builds into.
# Usage: scripts/ci/cmux-tui-warm-target.sh  (from any directory; prints one path)
#
# On an owned Mac (a `-glaeda` runner) the target is kept between jobs, per runner and
# workspace, so a dispatch rebuilds only the crates its commit changed. The Actions cache
# never warms this job there: only feat-cmux-next may save from an owned mini, and nothing
# dispatches cmux-tui.yml on feat-cmux-next, so the repository held no cmux-tui-macos entry
# and every macOS job compiled the workspace cold (2026-11-08: clippy 3.6 min, then the
# focused filter's test build 10.6 min of a 30 min job; 1 of 72 dispatches since 11-07
# passed, several on the 40 min timeout).
#
# Anywhere else it prints cmux-tui/target, the job's old cold target.
#
# The tree lives under ~/Library/Caches/cmux-next-ci/cmux-tui-cargo/<worker key>, where HQ's
# disk-pressure pass already bounds per-runner build trees (build-fleet/disk-pressure.sh:
# idle for 12 h it goes, and below the lend floor the least recently written go first).
# Here, another toolchain's tree goes when the helper runs, and a tree over 24 GiB starts
# over cold.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ "${RUNNER_NAME:-}" != *-glaeda* ]]; then
  printf '%s\n' "$repo_root/cmux-tui/target"
  exit 0
fi

# RUNNER_NAME isolates the host's concurrent runner slots: one runner runs one job at a
# time, so no other job writes this tree while this one builds. Cargo's fingerprints hold
# absolute source paths, so a workspace move is a new tree.
worker_key="$(printf '%s\n' "${RUNNER_NAME:?}" "$repo_root" | shasum -a 256 | cut -c1-16)"
# Keyed by the pinned toolchain file, not `rustc -vV`, so the job can pick the target
# before the toolchain is installed. The selected Xcode (its path, version and SDK build)
# covers the C compiler and SDK that build scripts use, which Cargo's fingerprints do not see.
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || echo none)}"
xcode_version="$(xcodebuild -version 2>/dev/null || echo none)"
sdk_build="$(xcrun --sdk macosx --show-sdk-build-version 2>/dev/null || echo none)"
toolchain_key="$( { cat "$repo_root/cmux-tui/rust-toolchain.toml"; uname -m; echo "$developer_dir";
  echo "$xcode_version"; echo "$sdk_build"; } | shasum -a 256 | cut -c1-16)"
worker_root="${HOME:?}/Library/Caches/cmux-next-ci/cmux-tui-cargo/$worker_key"
target="$worker_root/rust-$toolchain_key"
mkdir -p "$worker_root"

for previous in "$worker_root"/rust-*; do
  [[ "$previous" != "$target" && -d "$previous" && ! -L "$previous" ]] || continue
  echo "removing another toolchain's cmux-tui target: $previous" >&2
  rm -rf -- "$previous"
done

limit_gib="${CMUX_TUI_WARM_TARGET_MAX_GIB:-24}"
if [[ -d "$target" ]]; then
  size_kib="$(du -sk "$target" | cut -f1)"
  if (( size_kib > limit_gib * 1024 * 1024 )); then
    echo "kept cmux-tui target over $limit_gib GiB; building cold: $target" >&2
    rm -rf -- "$target"
  fi
fi
mkdir -p "$target"
printf '%s\n' "$target"
