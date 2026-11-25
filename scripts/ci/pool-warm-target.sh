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
# On the pool the tree is cargo's own: WORKSPACE/target (CMUX_POOL_WARM_TARGET_WORKSPACE, default
# cmux-tui), the path the R2 cache restores into. restore claims the kept tree by renaming it there
# from ~/.cache/cmux-next-ci/pool-cargo/NAME (one rename on one disk, so two jobs never share it), and
# record renames it back. A miss leaves WORKSPACE/target to the R2 restore, so a miss builds on R2's
# third-party crates instead of from nothing, and record keeps that tree for the next job for the
# price of a rename. Why: the tree was keyed by RUNNER_NAME, and a pool VM's runners come and go
# under new names, so 35 of 539 jobs (w76-w83) found theirs; the other 504 compiled all 576 units
# cold (job 139441164430: 14 min 44 s of cargo) without R2, then spent 19 s measuring a 13 GB tree
# no job would find. The slot is now keyed by HOME and the workspace path: every job on the VM user.
#
# restore: on a hit (a tree with a recorded manifest) moves it into place and writes linked=true;
# on the pool, hit or miss, keep=true (record runs). Then gives every source whose bytes equal the
# ones the last recorded build saw its recorded mtime back (scripts/blacksmith-testbox-source-mtimes.py,
# which compares git blob ids). A changed, added or unrecorded file keeps its fresh mtime, so Cargo
# rebuilds what it feeds and every crate that depends on it; nothing changed bytes is ever backdated.
# The manifest is consumed here: a job that ends before `record` (cancelled, timed out) leaves none,
# and on the pool its tree goes with its work directory. A tree without a manifest, another
# toolchain's tree or an old layout is moved out (to ~/.cmux-job-trash, which the job-done hook
# empties, else removed); a kept tree over CMUX_POOL_WARM_TARGET_MAX_GIB (16) starts over, and with
# less than CMUX_POOL_WARM_TARGET_MIN_FREE_GIB (40) free nothing is kept.
#
# On a sticky disk (Blacksmith) the tree stays on the disk: restore writes CARGO_TARGET_DIR and
# linked=true, hit or miss, and record writes the manifest there.
#
# record (after the cargo steps and the R2 save, success or failure, never on cancel): writes the
# source manifest into the tree, describing the checkout it was just built from, and on the pool
# moves the tree back into the slot.
#
# Anywhere but the persistent pool or a mounted disk both commands do nothing.
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
workspace="${CMUX_POOL_WARM_TARGET_WORKSPACE:-cmux-tui}"
[[ "$workspace" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$workspace" != *..* ]] || { echo "invalid workspace: $workspace" >&2; exit 2; }
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

toolchain_hash() {
  # What builds the tree that Cargo's fingerprints do not see: the build scripts' C
  # compiler and zig (ghostty-vt-sys), the host and its system libraries.
  { rustc -vV 2>/dev/null || echo no-rustc; cargo -V 2>/dev/null || echo no-cargo; cat "$repo/cmux-tui/rust-toolchain.toml" 2>/dev/null || true
    uname -m; clang --version 2>/dev/null | head -n 1 || true; "${CMUX_ZIG:-zig}" version 2>/dev/null || true
    grep -E '^(ID|VERSION_ID)=' /etc/os-release 2>/dev/null || true; } | sha256sum | cut -c1-16
}
# Moves a tree out of the way: into the job-done hook's trash on the same disk (a rename), else removed.
discard() {
  local trash="$HOME/.cmux-job-trash"
  if pool_runner && mkdir -p "$trash" 2>/dev/null && mv -T -- "$1" "$trash/pool-warm-$(date +%s%N)-$$" 2>/dev/null; then return 0; fi
  rm -rf -- "$1"
}
too_big() { (($(du -sxk "$1" | cut -f1) > max_gib * 1024 * 1024)); }
free_enough() {
  local free_kib
  free_kib="$(df -Pk "$1" | awk 'NR == 2 { print $4 }')"
  [[ "$free_kib" =~ ^[0-9]+$ ]] && ((free_kib >= min_free_gib * 1024 * 1024)) && return 0
  echo "pool warm target: ${free_kib:-unknown} KiB free, under $min_free_gib GiB; nothing kept"
  return 1
}
slot_dir() { printf '%s\n' "$(pool_root)/$(printf '%s\n' "$HOME" "$repo" | sha256sum | cut -c1-16)"; }

restore_pool() {
  local root slot here="$repo/$workspace/target" previous
  root="$(pool_root)"; slot="$(slot_dir)/tree-$(toolchain_hash)"
  mkdir -p "$root" "$(dirname "$slot")"
  # The old layout (a tree per runner name), other workspaces' slots stay; this slot's other toolchains go.
  for previous in "$root"/*/rust-* "$(dirname "$slot")"/tree-*; do
    [[ "$previous" != "$slot" && -d "$previous" && ! -L "$previous" ]] || continue
    echo "pool warm target: moving out $previous"
    discard "$previous"
  done
  if [[ "$(stat -c %d "$root")" != "$(stat -c %d "$repo")" ]]; then
    echo "pool warm target: miss ($root and $repo are on different disks); R2 restore, nothing kept"
    return 0
  fi
  if ! free_enough "$root"; then
    [[ -e "$slot" ]] && discard "$slot"
    return 0
  fi
  echo "keep=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  local manifest="$slot/$manifest_name"
  if [[ -d "$slot" && ! -L "$slot" && -f "$manifest" && ! -L "$manifest" && ! -e "$here" ]] && ! too_big "$slot" \
    && mv -T -- "$slot" "$here" 2>/dev/null; then
    mv -- "$here/$manifest_name" "$here/$manifest_name.consumed"
    echo "pool warm target: hit, built from $(head -c 40 "$here/.pool-warm-source" 2>/dev/null | tr -cd '0-9a-f')"
    python3 -I "$mtimes" restore "$repo" "$here/$manifest_name.consumed"
    rm -f -- "$here/$manifest_name.consumed"
    echo "linked=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    return 0
  fi
  if [[ -e "$slot" ]]; then
    echo "pool warm target: miss (the kept tree has no recorded build, is over $max_gib GiB or $here exists); moving it out"
    discard "$slot"
  else
    echo "pool warm target: miss (nothing kept for this VM yet); R2 restore, and record keeps this job's tree"
  fi
}

restore() {
  if ! usable; then
    echo "pool warm target: miss (${RUNNER_NAME:-no runner name} is not a persistent pool runner and no sticky disk is mounted${disk:+ at $disk}); cold build"
    return 0
  fi
  if pool_runner; then restore_pool; return 0; fi
  # A sticky disk is this job's own clone. Cargo's fingerprints hold absolute source paths, so
  # another workspace path is another tree.
  local worker toolchain root target
  worker="$(printf '%s\n' sticky-disk "$repo" | sha256sum | cut -c1-16)"
  toolchain="$(toolchain_hash)"
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
  min_free_gib="${CMUX_POOL_WARM_TARGET_DISK_MIN_FREE_GIB:-8}"
  if ! free_enough "$root"; then
    rm -rf -- "$target"
    return 0
  fi
  if [[ -d "$target" ]] && too_big "$target"; then
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
  echo "pool warm target: $target"
}

write_manifest() {
  rm -f -- "$1/.pool-warm-source"
  python3 -I "$mtimes" record "$repo" "$1/$manifest_name"
  git -C "$repo" rev-parse HEAD > "$1/.pool-warm-source" 2>/dev/null || true
}

record() {
  if pool_runner; then
    local here="$repo/$workspace/target" slot
    slot="$(slot_dir)/tree-$(toolchain_hash)"
    if [[ ! -d "$here" || -L "$here" ]]; then
      echo "pool warm target: no $here; nothing to record"
      return 0
    fi
    if [[ -e "$slot" ]]; then
      echo "pool warm target: another job kept a tree for this VM first; this one goes with the work directory"
      return 0
    fi
    write_manifest "$here"
    mkdir -p "$(dirname "$slot")"
    mv -T -- "$here" "$slot"
    echo "pool warm target: kept $here for the next job on this VM"
    return 0
  fi
  local target="${CARGO_TARGET_DIR:-}"
  if ! disk_mounted || [[ -z "$target" || "$target" != "$(pool_root)"/*/rust-* || ! -d "$target" || -L "$target" ]]; then
    echo "pool warm target: CARGO_TARGET_DIR is not this job's warm tree; nothing to record"
    return 0
  fi
  write_manifest "$target"
  echo "pool warm target: recorded the tree for the next job on the sticky disk $disk"
}

"$command"
