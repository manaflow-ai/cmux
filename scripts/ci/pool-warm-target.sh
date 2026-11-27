#!/usr/bin/env bash
# A Cargo target kept between one Linux pool runner's jobs, for a cargo job on the
# persistent pool (build-fleet/swift-linux-builder/gha-runners: a `cmux-runner-pool-*`
# runner keeps its HOME across jobs; the job-done hook wipes only work/ and /tmp).
#
# usage: scripts/ci/pool-warm-target.sh restore|record NAME [DISK]
#   (from the repository root, after the pinned Rust is set up; NAME names the job's tree)
#
# DISK: a mounted Blacksmith sticky disk, for the same job when RUNNER_POOLS sends it to
# Blacksmith instead (the pool is down or overflowing; run 44977580895, job 137071412072
# compiled 89 workspace units in 4 min 52 s after rust-cache restored the third-party
# ones). The tree lives on the disk instead of under HOME; the workflow mounts it
# read-only for pull requests and commits it only from feat-cmux-next pushes. Without a
# mounted DISK on a Blacksmith runner both commands do nothing.
#
# Why: cmux-next.yml's fast tier (cargo) restored a Swatinem/rust-cache entry, which holds
# third-party builds only, and found none on the pool ("No cache found"), so every run
# compiled all 495 units of `cargo test --no-run -p cmux-tui-core -p cmux-layout-reducer`
# cold: 9 min 45 s of a 14 min 22 s job (run 44972969020, job 137057163114, 2026-11-22).
# A kept target alone is not enough: the fresh checkout gives every source a new mtime,
# so Cargo would rebuild every workspace crate.
#
# restore: picks this runner's tree under ~/.cache/cmux-next-ci/pool-cargo/NAME, writes
# CARGO_TARGET_DIR to GITHUB_ENV and linked=true to GITHUB_OUTPUT, then gives every source
# whose bytes equal the ones the last recorded build saw its recorded mtime back
# (scripts/blacksmith-testbox-source-mtimes.py, which compares git blob ids). A changed,
# added or unrecorded file keeps its fresh mtime, so Cargo rebuilds what it feeds and every
# crate that depends on it; nothing changed bytes is ever backdated. The manifest is
# consumed here: a job that ends before `record` (cancelled, timed out) leaves none, and
# the next job rebuilds the workspace crates rather than trust a target that job changed.
# Another toolchain's tree is removed, a tree over CMUX_POOL_WARM_TARGET_MAX_GIB (16)
# starts over cold, and with less than CMUX_POOL_WARM_TARGET_MIN_FREE_GIB (40) free on the
# disk the tree is removed and the job builds in cmux-tui/target as before.
#
# record (after the cargo steps, success or failure, never on cancel): writes the source
# manifest into the tree, describing the checkout the tree was just built from.
#
# Anywhere but the persistent pool both commands do nothing, and the job builds cold.
set -euo pipefail

if (($# != 2 && $# != 3)) || [[ "$1" != restore && "$1" != record ]]; then
  echo "usage: $0 restore|record NAME [DISK]" >&2
  exit 2
fi
command=$1 name=$2 disk=${3:-}
[[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "invalid name: $name" >&2; exit 2; }

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mtimes="$repo/scripts/blacksmith-testbox-source-mtimes.py"
manifest_name=.cmux-testbox-source-mtimes.tsv
max_gib="${CMUX_POOL_WARM_TARGET_MAX_GIB:-16}"
min_free_gib="${CMUX_POOL_WARM_TARGET_MIN_FREE_GIB:-40}"
[[ "$max_gib" =~ ^[0-9]+$ && "$min_free_gib" =~ ^[0-9]+$ ]] || { echo "the GiB bounds must be integers" >&2; exit 2; }

pool_runner() { [[ "${RUNNER_NAME:-}" == cmux-runner-pool-* && -n "${HOME:-}" ]]; }
# CMUX_POOL_WARM_TARGET_TEST_MOUNTED names a directory the test treats as a mounted disk.
disk_mounted() {
  [[ -n "$disk" && "$disk" == /* && -d "$disk" ]] || return 1
  [[ "${CMUX_POOL_WARM_TARGET_TEST_MOUNTED:-}" == "$disk" ]] || mountpoint -q "$disk"
}
usable() { pool_runner || disk_mounted; }
pool_root() {
  if pool_runner; then printf '%s\n' "$HOME/.cache/cmux-next-ci/pool-cargo/$name"; else printf '%s\n' "$disk/$name"; fi
}

restore() {
  if ! usable; then
    echo "pool warm target: miss (${RUNNER_NAME:-no runner name} is not a persistent pool runner and no sticky disk is mounted${disk:+ at $disk}); cold build"
    return 0
  fi
  # One runner runs one job at a time, so RUNNER_NAME keeps a pool tree to this job (a sticky
  # disk is this job's own clone). Cargo's fingerprints hold absolute source paths, so another
  # workspace path is another tree.
  local worker toolchain root target owner="$RUNNER_NAME"
  disk_mounted && ! pool_runner && owner=sticky-disk
  worker="$(printf '%s\n' "$owner" "$repo" | sha256sum | cut -c1-16)"
  # What builds the tree that Cargo's fingerprints do not see: the build scripts' C
  # compiler and zig (ghostty-vt-sys), the host and its system libraries.
  toolchain="$( { rustc -vV 2>/dev/null || echo no-rustc; cargo -V 2>/dev/null || echo no-cargo; cat "$repo/cmux-tui/rust-toolchain.toml" 2>/dev/null || true
    uname -m; clang --version 2>/dev/null | head -n 1 || true; "${CMUX_ZIG:-zig}" version 2>/dev/null || true
    grep -E '^(ID|VERSION_ID)=' /etc/os-release 2>/dev/null || true; } | sha256sum | cut -c1-16)"
  root="$(pool_root)/$worker"
  target="$root/rust-$toolchain"
  mkdir -p "$root"
  local previous
  for previous in "$root"/rust-*; do
    [[ "$previous" != "$target" && -d "$previous" && ! -L "$previous" ]] || continue
    echo "pool warm target: removing another toolchain's tree $previous"
    rm -rf -- "$previous"
  done
  # A sticky disk is its own filesystem, sized for the tree: it needs room for one build only.
  pool_runner || min_free_gib="${CMUX_POOL_WARM_TARGET_DISK_MIN_FREE_GIB:-8}"
  local free_kib
  free_kib="$(df -Pk "$root" | awk 'NR == 2 { print $4 }')"
  if [[ ! "$free_kib" =~ ^[0-9]+$ ]] || ((free_kib < min_free_gib * 1024 * 1024)); then
    echo "pool warm target: miss (${free_kib:-unknown} KiB free, under $min_free_gib GiB); removing the tree, cold build"
    rm -rf -- "$target"
    return 0
  fi
  if [[ -d "$target" ]] && (($(du -sxk "$target" | cut -f1) > max_gib * 1024 * 1024)); then
    echo "pool warm target: the kept tree is over $max_gib GiB; starting it over cold"
    rm -rf -- "$target"
  fi
  mkdir -p "$target"
  local manifest="$target/$manifest_name" consumed="$target/$manifest_name.consumed"
  rm -f -- "$consumed"
  if [[ -f "$manifest" && ! -L "$manifest" ]]; then
    mv -- "$manifest" "$consumed"
    echo "pool warm target: hit, built from $(head -c 40 "$target/.pool-warm-source" 2>/dev/null | tr -cd '0-9a-f')"
  else
    rm -f -- "$manifest"
    echo "pool warm target: miss (no recorded build in $target); the third-party crates it holds stay, workspace crates rebuild"
  fi
  python3 -I "$mtimes" restore "$repo" "$consumed"
  rm -f -- "$consumed"
  echo "CARGO_TARGET_DIR=$target" >> "${GITHUB_ENV:-/dev/null}"
  echo "linked=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "pool warm target: $target ($(du -sxh "$target" | cut -f1))"
}

record() {
  local target="${CARGO_TARGET_DIR:-}"
  if ! usable || [[ -z "$target" || "$target" != "$(pool_root)"/*/rust-* || ! -d "$target" || -L "$target" ]]; then
    echo "pool warm target: CARGO_TARGET_DIR is not this job's pool tree; nothing to record"
    return 0
  fi
  rm -f -- "$target/.pool-warm-source"
  python3 -I "$mtimes" record "$repo" "$target/$manifest_name"
  git -C "$repo" rev-parse HEAD > "$target/.pool-warm-source" 2>/dev/null || true
  echo "pool warm target: recorded $(du -sxh "$target" | cut -f1) for the next job on $(pool_runner && echo "$RUNNER_NAME" || echo "the sticky disk $disk")"
}

"$command"
