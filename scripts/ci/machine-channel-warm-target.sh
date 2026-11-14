#!/usr/bin/env bash
# Warm cargo target for the Cloud machine channel's Linux musl legs (lto=thin in
# .github/workflows/cmux-tui-build-package.yml), kept on a Blacksmith sticky disk.
#
# usage: scripts/ci/machine-channel-warm-target.sh restore|record DISK TRIPLE
#
# Why: the legs restored a Swatinem/rust-cache entry, which holds dependency
# builds only. Every leg compiled all 138 workspace crates (ghostty-vt-sys's zig
# build, cmux-tui-core, acpmux, cmux-tui), and the entry itself was useless or
# gone on 12 of 16 legs: an exact-key hit built with an older release profile
# (the key leaves the profile out, and an exact hit is never saved again), or
# no entry at all a few minutes after it was saved (evicted). The build step
# ranged 4.28 to 7.57 min over 8 builds (2026-11-13). A sticky disk is the
# previous build's whole target dir, mounted in seconds and never evicted.
#
# restore (before the build): when DISK is mounted, link cmux-tui/target and
# the cargo registry to it, then give every source file whose content equals
# the one the snapshot was built from its recorded mtime back
# (scripts/blacksmith-testbox-source-mtimes.py), so Cargo rebuilds only what
# changed. A changed file keeps its fresh mtime: correctness never depends on
# the snapshot. Without a mounted disk it does nothing (cold build).
#
# record (after the build, before the sticky disk's post step commits it):
# bound the disk (scripts/blacksmith-testbox-target-prune.sh), then record the
# source mtimes and the commit next to the artifacts.
#
# Build output here is for an explicit zig -Dtarget (the musl triple, never the
# host), so ghostty-vt-sys's library does not depend on the build host's CPU.
# The mtimes helper drops output built on another CPU model; its CPU
# fingerprint is pinned to the triple, so it keeps this output on every host.
set -euo pipefail

if (($# != 3)) || [[ "$1" != restore && "$1" != record ]]; then
  echo "usage: $0 restore|record DISK TRIPLE" >&2
  exit 2
fi
command=$1 disk=$2 triple=$3
[[ "$triple" =~ ^[a-z0-9_]+-[a-z0-9_-]+$ ]] || { echo "invalid triple: $triple" >&2; exit 2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
target="$disk/target"
link="$repo/cmux-tui/target"
manifest="$target/.cmux-testbox-source-mtimes.tsv"
source_record="$target/.machine-channel-warm-source"
registry="${CARGO_HOME:-$HOME/.cargo}/registry"
# 40 GiB: one leg's six cargo groups leave about 10 GB of release output.
max_bytes="${MACHINE_CHANNEL_WARM_MAX_BYTES:-$((40 * 1024 * 1024 * 1024))}"

cpuinfo="${RUNNER_TEMP:-/tmp}/machine-channel-warm-cpu-$triple"
printf 'model name\t: zig -Dtarget=%s\nflags\t: %s\n' "$triple" "$triple" > "$cpuinfo"
export CMUX_TESTBOX_CPUINFO="$cpuinfo"

restore() {
  if ! mountpoint -q "$disk"; then
    echo "warm target: miss (no sticky disk mounted at $disk); cold build"
    return 0
  fi
  if [[ -e "$link" || -L "$link" ]]; then
    echo "warm target: miss ($link already exists); cold build"
    return 0
  fi
  mkdir -p "$target" "$disk/cargo-registry"
  if [[ -f "$source_record" && ! -L "$source_record" ]]; then
    echo "warm target: hit, built from $(head -c 40 "$source_record" | tr -cd '0-9a-f')"
  else
    echo "warm target: miss (empty sticky disk); cold build"
  fi
  # Crates fetched before this step (cargo install) join the disk's registry.
  if [[ -d "$registry" && ! -L "$registry" ]]; then
    cp -a --update=none "$registry/." "$disk/cargo-registry/"
    rm -rf "$registry"
  fi
  mkdir -p "$(dirname "$registry")"
  [[ -L "$registry" ]] || ln -s "$disk/cargo-registry" "$registry"
  ln -s "$target" "$link"
  python3 -I "$repo/scripts/blacksmith-testbox-source-mtimes.py" restore "$repo" "$manifest"
  echo "warm target: $(du -sxh "$target" | cut -f1) of build output, $(du -sxh "$disk/cargo-registry" | cut -f1) of crates"
}

record() {
  if [[ "$(readlink "$link" 2>/dev/null || true)" != "$target" ]]; then
    echo "warm target: $link is not linked to the sticky disk; nothing to record"
    return 0
  fi
  bash "$repo/scripts/ci/timeout.sh" 600 bash "$repo/scripts/blacksmith-testbox-target-prune.sh" "$target" "$max_bytes" \
    || echo "warning: prune failed; recording as is" >&2
  rm -f "$source_record"
  python3 -I "$repo/scripts/blacksmith-testbox-source-mtimes.py" record "$repo" "$manifest"
  git -C "$repo" rev-parse HEAD > "$source_record"
  echo "warm target: recorded $(du -sxh "$target" | cut -f1) of build output for $(cat "$source_record")"
}

"$command"
