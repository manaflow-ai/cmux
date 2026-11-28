#!/usr/bin/env bash
# check-no-godfiles.sh's "grown past it by" names the oldest commit of the run of
# commits, newest first, in which a Rust file is over its limit. The history comes
# from one git log for every file and the blob counts from one git cat-file stream,
# so this pins the counts (wc -l and grep -c semantics, a last line without a newline,
# fn lines) and the walk (merges, files touched together) against a fixture repo.
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-godfiles-grower.XXXXXX")"
git_fixture_trap_exit 'rm -rf "$tmp"'
fail() { echo "FAIL: $*" >&2; exit 1; }

repo="$tmp/repo"; src="$repo/cmux-tui/crates/fixture/src"
mkdir -p "$repo/Packages/macOS/CmuxNext" "$src"
git -C "$repo" init -q -b main
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
lines() { local i; for (( i = 0; i < $1; i++ )); do echo "// $i"; done; }
fns() { local i; for (( i = 0; i < $1; i++ )); do echo "pub(crate) async fn f$i() {}"; done; }
commit() { git -C "$repo" add -A; git -C "$repo" commit -qm "$1"; }
touch "$repo/Packages/macOS/CmuxNext/.keep"

# a.rs: under, over (c-a1), more over (c-a2): c-a1 grew it.
lines 900 > "$src/a.rs"; commit base
lines 1100 > "$src/a.rs"; lines 10 > "$src/b.rs"; commit c-a1
lines 1150 > "$src/a.rs"; commit c-a2
# b.rs: 1000 lines plus one with no newline: wc -l says 1000, under; then 61 fns (c-b1).
{ lines 1000; printf 'tail'; } > "$src/b.rs"; commit c-b0
{ fns 61; printf 'tail'; } > "$src/b.rs"; commit c-b1
# c.rs grows on a side branch (c-c1) merged into main.
git -C "$repo" checkout -q -b side
lines 1300 > "$src/c.rs"; commit c-c1
git -C "$repo" checkout -q main
echo x > "$repo/other.txt"; commit c-main
git -C "$repo" merge -q --no-ff -m merge-side side

GODFILES_WARN_SLACK=0 bash "$ROOT_DIR/scripts/cmux-next/check-no-godfiles.sh" --only rust "$repo/Packages/macOS/CmuxNext" > "$tmp/out" 2>&1 && fail "the fixture's files must fail"
want() { grep -q "$1.rs has .*grown past it by: [0-9a-f]* test [0-9-]*: $2\]" "$tmp/out" || { cat "$tmp/out"; fail "$1.rs must be grown past it by $2"; }; }
want a c-a1
want b c-b1
want c c-c1
grep -q 'b.rs has 61 lines, 61 fns' "$tmp/out" || { cat "$tmp/out"; fail "a last line without a newline is not a line"; }
GODFILES_NO_BLAME=1 GODFILES_WARN_SLACK=0 bash "$ROOT_DIR/scripts/cmux-next/check-no-godfiles.sh" --only rust "$repo/Packages/macOS/CmuxNext" > "$tmp/out" 2>&1 || true
grep -q 'grown past it by' "$tmp/out" && fail "GODFILES_NO_BLAME=1 must skip the attribution"
echo "godfiles grower: ok"
