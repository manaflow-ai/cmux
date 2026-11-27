#!/usr/bin/env bash
# The workspace half of the R2 cargo cache for the cmux-tui package legs that run off Blacksmith
# (.github/workflows/cmux-tui-build-package.yml): what a build added on top of the dependency entry
# (`Key the cargo build in R2`), saved per commit, so the next leg rebuilds only what its commit changed.
#
# usage: scripts/ci/cargo-target-delta.sh apply TARGET OVERLAY STAMP TRIPLE
#        scripts/ci/cargo-target-delta.sh pack  TARGET STAMP OUT TRIPLE
#
# Why: the dependency entry is stripped of the workspace's own output (scripts/ci/cargo_target_strip.py),
# and a cmux-runner-pool runner has no sticky disk (scripts/ci/machine-channel-warm-target.sh mounts one
# on Blacksmith only), so every pool leg compiled the whole workspace. aarch64-apple-darwin on Linux,
# job 139565194555 (2026-11-25, cmux-runner-pool-e1c-0137-3): "warm target: miss (no sticky disk
# mounted ...)", cargo group 1 1462 s, of it acpmux 778 s, cmux-tui-core 637 s and ghostty-vt-sys's zig
# build 205 s, before the 448 s fat-LTO link. That leg is the nightly tree's critical path
# (cmuxterm-hq goals/nightly-30min.md). A per-runner kept target (scripts/ci/pool-warm-target.sh) does
# not fit: the fat darwin target is ~39 GB, a pool VM runs 4 runners on 200 GB, and a leg lands on a
# random one of hundreds of runners, so it would almost never find its own tree.
#
# apply (after the dependency entry is restored into TARGET; OVERLAY is the newest delta restored from R2,
# possibly empty): copies OVERLAY into TARGET with its mtimes, lists what it copied next to STAMP, gives
# every source whose bytes equal the ones the delta's build saw its recorded mtime back
# (scripts/blacksmith-testbox-source-mtimes.py, as the sticky disk does), then touches STAMP. A changed
# file keeps its fresh mtime, so Cargo rebuilds it and its dependents: correctness never depends on the
# delta. With an empty OVERLAY it only touches STAMP (cold workspace build, as before).
#
# pack (after "Stage binary" and the uploads, before the dependency strip): OUT gets hard links of every
# file under TARGET written after STAMP (or, under incremental/, linked after it) plus every file apply copied (a crate Cargo found fresh is not
# rewritten, and the next leg needs it too), the source mtimes of this checkout and the commit. OUT is
# then saved to R2 under a per-commit key; its archive is the delta against the dependency entry, never
# a delta of a delta.
#
# The CPU fingerprint is pinned to TRIPLE as machine-channel-warm-target.sh pins it: the build output is
# for an explicit zig -Dtarget, so it is valid on every pool host; TRIPLE host keeps the real CPU.
# scripts/ci/tests/cargo-target-delta.test.sh.
set -euo pipefail

usage() {
  echo "usage: $0 apply TARGET OVERLAY STAMP TRIPLE | pack TARGET STAMP OUT TRIPLE" >&2
  exit 2
}
(($# == 5)) || usage
command=$1
case "$command" in
  apply) target=$2 overlay=$3 stamp=$4 triple=$5 ;;
  pack) target=$2 stamp=$3 out=$4 triple=$5 ;;
  *) usage ;;
esac
[[ "$triple" == host || "$triple" =~ ^[a-z0-9_]+-[a-z0-9_-]+$ ]] || { echo "invalid triple: $triple" >&2; exit 2; }

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mtimes="$repo/scripts/blacksmith-testbox-source-mtimes.py"
manifest_name=.cmux-testbox-source-mtimes.tsv
source_name=.cargo-target-delta-source
list="$stamp.list"

# TRIPLE host (the cmux-next fast tier builds for the machine it runs on) keeps this machine's CPU: apply
# then drops the native-CPU build output another CPU made (blacksmith-testbox-source-mtimes.py), as the
# pool warm target does.
if [[ "$triple" != host ]]; then
  cpuinfo="${RUNNER_TEMP:-/tmp}/cargo-target-delta-cpu-$triple"
  printf 'model name\t: zig -Dtarget=%s\nflags\t: %s\n' "$triple" "$triple" > "$cpuinfo"
  export CMUX_TESTBOX_CPUINFO="$cpuinfo"
fi

# Hard links where TARGET and the other tree share a filesystem (both under the workspace), else copies.
copy_tree() { # <from> <to>: every entry, mtimes kept
  cp -a --link --remove-destination "$1/." "$2/" 2>/dev/null || cp -a --remove-destination "$1/." "$2/"
}

apply() {
  mkdir -p "$target" "$(dirname "$stamp")"
  : > "$list"
  if [[ -d "$overlay" && ! -L "$overlay" && -f "$overlay/$manifest_name" && ! -L "$overlay/$manifest_name" ]]; then
    (cd "$overlay" && find . \( -type f -o -type l \) ! -name "$manifest_name" ! -name "$source_name" -printf '%P\n') > "$list"
    copy_tree "$overlay" "$target"
    echo "cargo delta: hit, $(wc -l < "$list") files built from $(head -c 40 "$overlay/$source_name" 2>/dev/null | tr -cd '0-9a-f')"
    python3 -I "$mtimes" restore "$repo" "$target/$manifest_name"
  else
    echo "cargo delta: miss (no delta restored); the workspace crates build cold"
  fi
  rm -f -- "$target/$manifest_name" "$target/$source_name"
  [[ -z "$overlay" || ! -d "$overlay" ]] || rm -rf -- "$overlay"
  # Last: whatever the build writes from here on is newer than STAMP.
  touch "$stamp"
}

pack() {
  if [[ ! -f "$stamp" ]]; then
    echo "cargo delta: no stamp $stamp (apply did not run); nothing packed"
    return 0
  fi
  if [[ ! -d "$target" ]]; then
    echo "cargo delta: no $target$([[ ! -L "$target" ]] || echo " (a link to the missing $(readlink "$target"))"); nothing packed"
    return 0
  fi
  rm -rf -- "$out"
  mkdir -p "$out"
  local files="$out.files"
  {
    # rustc's incremental cache hard-links every codegen unit it reuses into a new session directory
    # (target/<triple>/release/incremental/<crate>/s-*), keeping the old mtime: -cnewer (the link
    # changed its ctime) keeps them, or the next leg would find the session missing them and
    # recompile those units. acpmux 2026-11-27: 16 of the session's 20 files were linked, 4 written.
    (cd "$target" && find . \( -type f -o -type l \) \( -newer "$stamp" -o \( -path '*/incremental/*' -cnewer "$stamp" \) \) -printf '%P\n')
    [[ ! -f "$list" ]] || while IFS= read -r path; do
      [[ -n "$path" && ( -f "$target/$path" || -L "$target/$path" ) ]] && printf '%s\n' "$path"
    done < "$list"
  } | grep -v -x -e "$manifest_name" -e "$source_name" -e '.cmux-testbox-cpu' | sort -u > "$files" || true
  if [[ -s "$files" ]]; then
    (cd "$target" && tr '\n' '\0' < "$files" | xargs -0 -r cp -a --parents --link -t "$out" 2>/dev/null) \
      || (cd "$target" && tr '\n' '\0' < "$files" | xargs -0 -r cp -a --parents --remove-destination -t "$out")
  fi
  python3 -I "$mtimes" record "$repo" "$out/$manifest_name"
  git -C "$repo" rev-parse HEAD > "$out/$source_name" 2>/dev/null || true
  echo "cargo delta: packed $(wc -l < "$files") files, $(du -sxh "$out" | cut -f1) (target $(du -sxh "$target/" | cut -f1))"
  rm -f -- "$files"
}

"$command"
