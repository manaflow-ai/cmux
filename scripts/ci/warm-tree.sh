#!/usr/bin/env bash
# Warm build trees for a fixed build seat: keep N built checkouts keyed by commit, restore the one
# nearest a job's ref into the seat, and build only the delta. `wsfactory warm` does the work
# (scripts/measure/workspace-factory/src/warm.rs); this builds it once per source and runs it.
#
#   scripts/ci/warm-tree.sh use  --store S --seat P --ref REV [--git DIR] [--always] [--no-checkout]
#   scripts/ci/warm-tree.sh save --store S --seat P [--keep N]
#   scripts/ci/warm-tree.sh list --store S
#
# P is a standalone git checkout (not a worktree) at a fixed path, with its build state inside it
# (SwiftPM .build, cargo target, -derivedDataPath under it). S is on P's volume (APFS clonefile).
# `use` restores the saved tree with the fewest commits to REV (unless the seat is already as
# near), then checks REV out in place: only files whose bytes differ get a new mtime. It does not
# touch submodules; run `git submodule update` after it as a checkout would. `save` after a good
# build of a trusted commit (a feat-cmux-next tip). The caller holds the seat (its slot lock).
# Each prints one JSON object. Exit 2 is a usage error, 1 a failure; a `use` with nothing saved
# is not one ("restored": false, and the ref is still checked out when the seat exists).
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
src="$repo/scripts/measure/workspace-factory"
key="$(cat "$src/Cargo.toml" "$src/Cargo.lock" "$src"/src/*.rs | { if command -v shasum >/dev/null; then shasum -a 256; else sha256sum; fi; } | cut -c1-16)"
cache="${WARM_TREE_BIN_CACHE:-$HOME/.cache/cmux-warm-tree}"
bin="$cache/wsfactory-$key"
if [[ ! -x "$bin" ]]; then
  # A worker's shared rustup has no default toolchain: use cmux-tui's, as the measure harnesses do.
  if [[ -z "${RUSTUP_TOOLCHAIN:-}" ]]; then
    RUSTUP_TOOLCHAIN="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$repo/cmux-tui/rust-toolchain.toml" 2>/dev/null || true)"
    [[ -n "$RUSTUP_TOOLCHAIN" ]] && export RUSTUP_TOOLCHAIN || unset RUSTUP_TOOLCHAIN
  fi
  mkdir -p "$cache"
  cargo build --quiet --release --manifest-path "$src/Cargo.toml" --target-dir "$cache/target-$key" >&2
  cp "$cache/target-$key/release/wsfactory" "$bin.tmp.$$"
  mv -f "$bin.tmp.$$" "$bin"
  rm -rf "$cache/target-$key"
fi
exec "$bin" warm "$@"
