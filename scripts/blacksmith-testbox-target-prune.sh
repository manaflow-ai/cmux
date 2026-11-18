#!/usr/bin/env bash
# Usage: blacksmith-testbox-target-prune.sh <target-dir> [max-bytes] [stale-days] [keep]
#
# Bounds the warm cmux-tui target dir before the Testbox commits it as the
# sticky disk of its branch family (`cmux-tui-target-v2-<family>`). Every box of
# that family clones that one snapshot,
# so it must stay small enough to clone fast and must not grow without limit.
#
# 1. Remove incremental-compilation dirs not touched for <stale-days> days.
#    Cargo creates one dir per crate and profile hash under
#    <profile>/incremental/, and an old hash (a changed toolchain, feature set,
#    or crate) is never used again.
# 2. Over <max-bytes>: remove every incremental dir. Dependency artifacts stay,
#    so the next box still skips the dependency build.
# 3. Still over: remove whole top-level entries (profiles, target triples),
#    least recently modified first, until under the bound. An empty dir is a
#    valid outcome; the next box then builds cold once.
#
# <keep> (optional) names one top-level entry that step 3 never removes: the
# triple a build leg just built, which the steps after its build still read
# (scripts/ci/machine-channel-warm-target.sh record). Its dir is often the
# least recently modified entry, so without this the prune removed the fresh
# binaries first. When the kept entry alone is over the bound, nothing more is
# removed, one line says so with the bytes, and the prune succeeds.
#
# The dir itself may be a mount point, so this only removes its contents.
set -euo pipefail

target="${1:?target dir}"
# 100 GiB: a cold feat-cmux-next session (workspace build, test build, test
# run, clippy --all-targets) leaves a 92 GB target dir (Testbox
# tbx_01m4ga0aa7r4zkaxqjbttdj0dq, 2026-10-09). A 40 GiB bound evicted whole
# profiles on every release, so the next box rebuilt test and clippy output.
# The sticky disk is 590 GB.
max_bytes="${2:-$((100 * 1024 * 1024 * 1024))}"
stale_days="${3:-3}"
[[ "$max_bytes" =~ ^[0-9]+$ && "$stale_days" =~ ^[0-9]+$ ]] || {
  echo "max-bytes and stale-days must be integers" >&2
  exit 2
}
keep="${4:-}"
[[ -z "$keep" || "$keep" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || {
  echo "keep must be the name of one top-level entry" >&2
  exit 2
}
keep_filter=()
[[ -z "$keep" ]] || keep_filter=(! -name "$keep")
if [[ ! -d "$target" ]]; then
  echo "prune: $target is absent; nothing to prune"
  exit 0
fi

size_of() { du -sxB1 "$1" | cut -f1; }
incremental_dirs() {
  find "$target" -mindepth 3 -maxdepth 4 -type d -path '*/incremental/*' \
    ! -path '*/incremental/*/*' "$@" -print0
}

before="$(size_of "$target")"
stale=0
while IFS= read -r -d '' dir; do
  rm -rf -- "$dir"
  stale=$((stale + 1))
done < <(incremental_dirs -mtime "+$stale_days")
size="$(size_of "$target")"
printf 'prune: %s bytes before, removed %s stale incremental dirs, %s bytes now (bound %s)\n' \
  "$before" "$stale" "$size" "$max_bytes"

if (( size > max_bytes )); then
  while IFS= read -r -d '' dir; do
    rm -rf -- "$dir"
  done < <(incremental_dirs)
  size="$(size_of "$target")"
  printf 'prune: over the bound; removed all incremental dirs, %s bytes now\n' "$size"
fi

while (( size > max_bytes )); do
  oldest="$(find "$target" -mindepth 1 -maxdepth 1 ${keep_filter[@]+"${keep_filter[@]}"} -printf '%T@ %p\n' | sort -n | head -n 1 | cut -d ' ' -f 2-)"
  if [[ -z "$oldest" ]]; then
    [[ -z "$keep" || ! -e "$target/$keep" ]] \
      || printf 'prune: still over the bound with only %s left (%s bytes, bound %s); nothing more is removed\n' "$keep" "$size" "$max_bytes"
    break
  fi
  rm -rf -- "$oldest"
  size="$(size_of "$target")"
  printf 'prune: over the bound; removed %s, %s bytes now\n' "${oldest#"$target"/}" "$size"
done
