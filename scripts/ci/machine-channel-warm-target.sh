#!/usr/bin/env bash
# Warm cargo target for the cmux-tui legs of .github/workflows/cmux-tui-build-package.yml,
# kept on a Blacksmith sticky disk: the Cloud machine channel's Linux musl legs (lto=thin)
# and the shipped fat-LTO legs (both musl targets and aarch64-apple-darwin built on Linux),
# each on its own disk, so thin and fat objects never mix.
#
# usage: scripts/ci/machine-channel-warm-target.sh restore|record|probe|release DISK TRIPLE
#        scripts/ci/machine-channel-warm-target.sh pool-dir TRIPLE
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
# record (after "Stage binary", in its own step, before the sticky disk's post
# step commits it; never in the build step, whose output the prune may remove):
# bound the disk (scripts/blacksmith-testbox-target-prune.sh), then record the
# source mtimes and the commit next to the artifacts. The prune removes
# target/TRIPLE (often the disk's least recently modified entry) only when it
# alone is over the bound, and only here, after staging read its binaries
# (#45963 kept it in record and pruned in restore; restore no longer prunes).
#
# MACHINE_CHANNEL_WARM_TOOLCHAIN (optional): what built the disk that Cargo does not
# track, such as the macOS cross toolchain (clang, lld, zig, the SDK version label)
# and the framework stubs it links against. record stores it; restore empties a
# disk whose stored value differs, or that has none, before linking it, so a new
# toolchain starts cold instead of linking objects the old one made. Unset, the
# disk is used as recorded (the thin legs).
#
# Pool runners (RUNNER_NAME cmux-runner-pool-*) mount no sticky disk, but keep HOME across
# jobs. There DISK may be the runner slot's own directory, `pool-dir TRIPLE` prints it
# ($HOME/.cache/cmux-next-ci/cmux-tui-fat-warm/RUNNER/TRIPLE), and it counts as mounted.
# Why: the aarch64-apple-darwin cross leg runs on pool hosts and built cold every push,
# 1475 s for the build step (job 139565194555, 2026-11-25: 270 workspace and 102 dependency
# crates recompiled after an exact R2 hit). Pool hosts are shared and have run out of disk
# (jobs 139596782005, 45713322066), so a pool tree is bounded tighter: record prunes it to
# MACHINE_CHANNEL_WARM_POOL_MAX_BYTES (48 GiB), and restore and release remove it outright when
# the filesystem has less than MACHINE_CHANNEL_WARM_POOL_MIN_FREE_BYTES (20 GiB) free: a cold
# build, never a full disk. The floor was 40 GiB, sized for a 39 GB tree; the darwin tree
# records 7.7 GB, and a pool host held 38.6 GB free after recording it, so 40 GiB removed
# every tree it had just recorded and the leg never ran warm (job 140059291498, 2026-11-26).
# 20 GiB still leaves room for a whole darwin build (7.7 GB of output) beside the tree.
# release runs last in the job ("Release the pool warm target"), never in record: the steps
# after record read cmux-tui/target through the link (the workspace delta's pack, the R2
# dependency save), and record's removal left them a dangling link, so the darwin leg saved
# neither (job 140189679068, 2026-11-26: "pool tree removed after record", then "cargo delta:
# no cmux-tui/target ...; nothing packed" and "r2-cache: cmux-tui/target does not exist").
# On a pool tree's first job the workflow's R2 restore has filled cmux-tui/target; restore
# moves it into the empty tree instead of refusing, so the tree starts from R2 (kept only
# when MACHINE_CHANNEL_WARM_SEED_EXACT=true says the restore was an exact, same-stamp hit).
# `probe` prints hit when DISK holds a recorded tree built with the current toolchain stamp
# (the workflow skips the R2 restore then), else miss.
#
# Build output here is for an explicit zig -Dtarget (the musl triple, never the
# host), so ghostty-vt-sys's library does not depend on the build host's CPU.
# The mtimes helper drops output built on another CPU model; its CPU
# fingerprint is pinned to the triple, so it keeps this output on every host.
set -euo pipefail

pool_runner() { [[ "${RUNNER_NAME:-}" =~ ^cmux-runner-pool-[A-Za-z0-9_.-]+$ && "${HOME:-}" == /* ]]; }
pool_root() { printf '%s' "$HOME/.cache/cmux-next-ci/cmux-tui-fat-warm"; }

if [[ "${1:-}" == pool-dir ]] && (($# == 2)); then
  [[ "$2" =~ ^[a-z0-9_]+-[a-z0-9_-]+$ ]] || { echo "invalid triple: $2" >&2; exit 2; }
  pool_runner || exit 0
  printf '%s/%s/%s\n' "$(pool_root)" "$RUNNER_NAME" "$2"
  exit 0
fi
if (($# != 3)) || [[ "$1" != restore && "$1" != record && "$1" != probe && "$1" != release ]]; then
  echo "usage: $0 restore|record|probe|release DISK TRIPLE | pool-dir TRIPLE" >&2
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
toolchain_record="$target/.machine-channel-warm-toolchain"
toolchain="${MACHINE_CHANNEL_WARM_TOOLCHAIN:-}"
registry="${CARGO_HOME:-$HOME/.cargo}/registry"
# 100 GiB, from measured use: after a build a leg's disk held 33.6-44.5 GB (run 44240874997,
# 2026-11-18: thin x86_64 33.6 GB, thin aarch64 44.5 GB, fat x86_64 41.0 GB, fat aarch64
# 38.8 GB; the same within 0.01 GB over 4 runs each). The old 40 GiB bound ("about 10 GB" per
# leg) was below that, so the prune removed whole top-level entries once a disk passed it: the
# leg's own target/<triple> (then "Stage binary" failed) or groups/ (groups 2-6 built cold).
# 100 GiB is 2.2x the largest leg and the bound the Testbox prune settled on
# (scripts/blacksmith-testbox-target-prune.sh). record caps it at 80% of the disk's real
# size (df), so it never exceeds the sticky disk, and prints that size and the largest entries.
# tests/test_ci_cmux_tui_fat_warm_target.py keeps it above measured use.
max_bytes="${MACHINE_CHANNEL_WARM_MAX_BYTES:-$((100 * 1024 * 1024 * 1024))}"
pool_max_bytes="${MACHINE_CHANNEL_WARM_POOL_MAX_BYTES:-$((48 * 1024 * 1024 * 1024))}"
pool_min_free="${MACHINE_CHANNEL_WARM_POOL_MIN_FREE_BYTES:-$((20 * 1024 * 1024 * 1024))}"

# DISK is this pool runner slot's own tree (never a path outside it).
pool_disk() {
  pool_runner || return 1
  [[ "$disk" == "$(pool_root)/$RUNNER_NAME/$triple" ]]
}
usable_disk() { mountpoint -q "$disk" 2>/dev/null || pool_disk; }
free_bytes() { df -B1 --output=avail "$1" 2>/dev/null | tail -n 1 | tr -cd '0-9'; }
# A pool tree below the free-space floor goes: the host's other jobs need the room more.
pool_room() {
  pool_disk || return 0
  mkdir -p "$disk"
  local avail
  avail="$(free_bytes "$disk")"
  [[ -n "$avail" ]] || return 0
  if ((avail < pool_min_free)); then
    echo "warm target: miss (pool host has $avail bytes free, under $pool_min_free); removing $target"
    rm -rf "$target"
    return 1
  fi
}

cpuinfo="${RUNNER_TEMP:-/tmp}/machine-channel-warm-cpu-$triple"
printf 'model name\t: zig -Dtarget=%s\nflags\t: %s\n' "$triple" "$triple" > "$cpuinfo"
export CMUX_TESTBOX_CPUINFO="$cpuinfo"

probe() {
  usable_disk || { echo miss; return 0; }
  local recorded=""
  [[ -f "$toolchain_record" && ! -L "$toolchain_record" ]] && recorded="$(head -c 4096 "$toolchain_record")"
  if [[ -f "$source_record" && ! -L "$source_record" && "$recorded" == "$toolchain" ]]; then
    echo hit
  else
    echo miss
  fi
}

restore() {
  if ! usable_disk; then
    echo "warm target: miss (no sticky disk mounted at $disk); cold build"
    return 0
  fi
  pool_room || { echo "warm target: cold build"; return 0; }
  # A pool tree's first job: the R2 restore filled cmux-tui/target; it seeds the empty tree.
  if pool_disk && [[ -d "$link" && ! -L "$link" ]] && [[ ! -e "$target" || -z "$(ls -A "$target")" ]]; then
    rm -rf "$target"
    mv "$link" "$target"
    # An exact R2 hit's key carries this toolchain stamp, so its objects are this toolchain's;
    # a prefix hit may be another toolchain's: no stamp, so the check below empties it.
    if [[ -n "$toolchain" && "${MACHINE_CHANNEL_WARM_SEED_EXACT:-}" == true ]]; then
      printf '%s' "$toolchain" > "$toolchain_record"
    fi
    echo "warm target: seeded $disk from the restored cmux-tui/target"
  fi
  if [[ -e "$link" || -L "$link" ]]; then
    echo "warm target: miss ($link already exists); cold build"
    return 0
  fi
  mkdir -p "$target" "$disk/cargo-registry"
  if [[ -n "$toolchain" && -n "$(ls -A "$target")" ]]; then
    local recorded=""
    [[ -f "$toolchain_record" && ! -L "$toolchain_record" ]] && recorded="$(head -c 4096 "$toolchain_record")"
    if [[ "$recorded" != "$toolchain" ]]; then
      echo "warm target: miss (toolchain changed: '${recorded:-none recorded}' -> '$toolchain'); emptying the disk"
      rm -rf "$target"
      mkdir -p "$target"
    fi
  fi
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
  # The disk's real size bounds the bound: at most 80% of the filesystem (df), so a smaller
  # disk than measured never fills. Printed with the largest entries, so growth is attributable.
  local bound=$max_bytes disk_bytes prune="$repo/scripts/blacksmith-testbox-target-prune.sh"
  ! pool_disk || ((pool_max_bytes >= bound)) || bound=$pool_max_bytes
  disk_bytes="$(df -B1 --output=size "$disk" 2>/dev/null | tail -n 1 | tr -cd '0-9')" || disk_bytes=""
  if [[ -n "$disk_bytes" ]] && ((disk_bytes > 0 && disk_bytes * 8 / 10 < bound)); then
    bound=$((disk_bytes * 8 / 10))
  fi
  df -B1 --output=size,used,avail "$disk" 2>/dev/null | sed 's/^/warm target: disk /' || true
  echo "warm target: prune bound $bound bytes (configured $max_bytes, disk ${disk_bytes:-unknown})"
  du -xB1 -d 2 "$target" 2>/dev/null | sort -rn | sed -n '2,9p' | sed "s#$target/##; s/^/warm target: largest /" || true
  # Keep the triple this leg built (3 = the prune's default stale days, then the kept entry):
  # the next leg's group 1 starts from it. "Stage binary" has already copied its binaries
  # (this runs in "Record the warm target", after it), so when the triple alone is still
  # over the bound a second pass may remove it too: the disk stays bounded, the next leg
  # rebuilds it, and nothing this job still reads is gone. This is the only prune: restore
  # never prunes, so a build never starts by removing warm output it would use.
  bash "$repo/scripts/ci/timeout.sh" 600 bash "$prune" "$target" "$bound" 3 "$triple" \
    || echo "warning: prune failed; recording as is" >&2
  if (( $(du -sxB1 "$target" | cut -f1) > bound )); then
    bash "$repo/scripts/ci/timeout.sh" 600 bash "$prune" "$target" "$bound" \
      || echo "warning: prune failed; recording as is" >&2
  fi
  rm -f "$source_record"
  python3 -I "$repo/scripts/blacksmith-testbox-source-mtimes.py" record "$repo" "$manifest"
  rm -f "$toolchain_record"
  [[ -z "$toolchain" ]] || printf '%s' "$toolchain" > "$toolchain_record"
  git -C "$repo" rev-parse HEAD > "$source_record"
  echo "warm target: recorded $(du -sxh "$target" | cut -f1) of build output for $(cat "$source_record")"
}

# Last in the job, after every step that reads cmux-tui/target: a pool tree on a host short of
# disk goes, with the link that now points at nothing.
release() {
  pool_disk || return 0
  if ! pool_room; then
    [[ "$(readlink "$link" 2>/dev/null || true)" != "$target" ]] || rm -f "$link"
    echo "warm target: pool tree removed at the end of the job (host short of disk)"
  fi
}

"$command"
