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

# A kept entry (the triple a build leg just built and still reads) is never
# removed: over the bound the oldest of the other entries goes, also when the
# kept one is the oldest of all.
keep="$work/keep"
fill "$keep/aarch64-unknown-linux-musl/release/cmux-tui" 300000
fill "$keep/release/build/host.bin" 300000
fill "$keep/debug/deps/libdep.rlib" 300000
touch -d '9 days ago' "$keep/aarch64-unknown-linux-musl"
touch -d '5 days ago' "$keep/release"
"$prune" "$keep" 700000 3 aarch64-unknown-linux-musl >/dev/null
[[ -f "$keep/aarch64-unknown-linux-musl/release/cmux-tui" ]] || fail "the kept entry was removed"
[[ ! -e "$keep/release" ]] || fail "the oldest entry beside the kept one survived"
[[ -f "$keep/debug/deps/libdep.rlib" ]] || fail "a newer entry was removed while an older one was enough"

# The kept entry alone over the bound: nothing of it goes, one line says so
# with the bytes, and the prune still succeeds.
out="$("$prune" "$keep" 100000 3 aarch64-unknown-linux-musl)" || fail "the prune failed with only the kept entry over the bound"
[[ -f "$keep/aarch64-unknown-linux-musl/release/cmux-tui" ]] || fail "the kept entry was removed when it alone is over the bound"
[[ ! -e "$keep/debug" ]] || fail "an entry beside the kept one survived over the bound"
said="$(grep -Ec '^prune: still over the bound with only aarch64-unknown-linux-musl left \([0-9]+ bytes, bound 100000\); nothing more is removed$' <<<"$out" || true)"
[[ "$said" == 1 ]] || fail "$said lines say the kept entry alone is over the bound, not 1"

# A kept name that is not one entry name is refused before anything goes.
for bad in .. a/b -x; do
  rc=0
  "$prune" "$keep" 1 3 "$bad" >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 2 ]] || fail "the kept name '$bad' gave exit $rc, not 2"
  [[ -f "$keep/aarch64-unknown-linux-musl/release/cmux-tui" ]] || fail "the kept name '$bad' removed an entry"
done

# A kept name that is not in the dir protects nothing, and no line names it
# (bound 1: the emptied dir is still over it, so the check for the kept entry runs).
out="$("$prune" "$keep" 1 3 no-such-entry)" || fail "the prune failed with a kept name that is not in the dir"
[[ ! -e "$keep/aarch64-unknown-linux-musl" ]] || fail "a kept name that is not in the dir protected another entry"
said="$(grep -c 'still over the bound' <<<"$out" || true)"
[[ "$said" == 0 ]] || fail "a line names a kept entry that is not in the dir"

# Without a kept name the old rule holds: that same entry goes (the Testbox).
fill "$keep/aarch64-unknown-linux-musl/release/cmux-tui" 300000
"$prune" "$keep" 100000 3 >/dev/null
[[ ! -e "$keep/aarch64-unknown-linux-musl" ]] || fail "without a kept name the oldest entry survived"

# An absent dir is not an error.
"$prune" "$work/absent" >/dev/null
echo "PASS: target prune keeps the warm disk bounded"
