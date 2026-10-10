#!/usr/bin/env bash
# The Testbox commits cmux-tui/target as one shared sticky disk, so the prune
# that runs before the commit must keep it bounded without removing the mount
# point itself: stale incremental dirs go first, then all incremental dirs,
# then whole profiles, oldest first.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prune="$root/scripts/blacksmith-testbox-target-prune.sh"
test -x "$prune"
if ! find . -maxdepth 0 -printf '' >/dev/null 2>&1 || ! du --version >/dev/null 2>&1; then
  echo "SKIP: needs GNU find and du (the Testbox and CI run Linux)"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
target="$work/target"
fill() { mkdir -p "$(dirname "$1")"; head -c "$2" /dev/zero >"$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

fill "$target/debug/deps/libdep.rlib" 100000
fill "$target/debug/incremental/fresh-abc/s-1/query.bin" 100000
fill "$target/debug/incremental/stale-def/s-1/query.bin" 100000
touch -d '10 days ago' "$target/debug/incremental/stale-def"
fill "$target/x86_64-pc-windows-gnu/debug/incremental/winstale-1/s/q.bin" 1000
touch -d '10 days ago' "$target/x86_64-pc-windows-gnu/debug/incremental/winstale-1"

# Under the bound: only stale incremental dirs go.
"$prune" "$target" 100000000 3 >/dev/null
[[ -d "$target/debug/incremental/fresh-abc" ]] || fail "a fresh incremental dir was removed"
[[ ! -e "$target/debug/incremental/stale-def" ]] || fail "a stale incremental dir survived"
[[ ! -e "$target/x86_64-pc-windows-gnu/debug/incremental/winstale-1" ]] || fail "a stale cross-target incremental dir survived"
[[ -f "$target/debug/deps/libdep.rlib" ]] || fail "dependency artifacts were removed"

# Over the bound: every incremental dir goes, dependency artifacts stay.
"$prune" "$target" 180000 3 >/dev/null
[[ ! -e "$target/debug/incremental/fresh-abc" ]] || fail "incremental dirs survived over the bound"
[[ -f "$target/debug/deps/libdep.rlib" ]] || fail "dependency artifacts were removed before incremental dirs"

# Still over: the oldest top-level entry goes first; the dir itself stays.
fill "$target/release/big.bin" 300000
touch -d '5 days ago' "$target/release"
"$prune" "$target" 250000 3 >/dev/null
[[ ! -e "$target/release" ]] || fail "the oldest profile survived"
[[ -f "$target/debug/deps/libdep.rlib" ]] || fail "a newer profile was removed while an older one was enough"
"$prune" "$target" 1 3 >/dev/null
[[ -d "$target" ]] || fail "the target dir (a mount point) was removed"
[[ -z "$(ls -A "$target")" ]] || fail "the target dir is not empty under a tiny bound"

# An absent dir is not an error.
"$prune" "$work/absent" >/dev/null
echo "PASS: target prune keeps the warm disk bounded"
