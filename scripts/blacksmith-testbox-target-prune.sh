#!/usr/bin/env bash
# Usage: blacksmith-testbox-target-prune.sh <target-dir> [max-bytes] [stale-days]
#
# Bounds the warm cmux-tui target dir before the Testbox commits it as the
# shared sticky disk `cmux-tui-target-v1`. Every box clones that one snapshot,
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
  oldest="$(find "$target" -mindepth 1 -maxdepth 1 -printf '%T@ %p\n' | sort -n | head -n 1 | cut -d ' ' -f 2-)"
  [[ -n "$oldest" ]] || break
  rm -rf -- "$oldest"
  size="$(size_of "$target")"
  printf 'prune: over the bound; removed %s, %s bytes now\n' "${oldest#"$target"/}" "$size"
done
