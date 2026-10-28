#!/usr/bin/env bash
# The cmux-tui tree key covers every file a cmux-tui crate embeds
# (include_str!/include_bytes!), so a commit that changes only an embedded file
# never reuses a published binary built from the old file (cx-t3e5, 2026-10-08).
# 1. The repository itself passes scripts/ci/check_cmux_tui_tree_inputs.py.
# 2. A fixture proves the check fails on an uncovered embed (literal and
#    multi-line), passes once the file is a blob input, and that the key then
#    moves when only the embedded file changes.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf '%s\n' "$@" >&2; exit 1; }
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

python3 "$ROOT/scripts/ci/check_cmux_tui_tree_inputs.py" --root "$ROOT" || fail "the repository's tree key misses embedded files (above)"

src="$TMP/src"
git_q init "$src"
mkdir -p "$src/cmux-tui/crates/a/src" "$src/scripts/cmux-next" "$src/scripts/ci" "$src/schemas/x"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$ROOT/scripts/ci/check_cmux_tui_tree_inputs.py" "$src/scripts/ci/"
printf 'tree cmux-tui\ngitlink ghostty-next\nblob scripts/cmux-next/build-layout-reducer-ffi.sh\n' > "$src/scripts/cmux-next/cmux-tui-tree-inputs.txt"
echo reducer > "$src/scripts/cmux-next/build-layout-reducer-ffi.sh"
echo '[package]' > "$src/cmux-tui/crates/a/Cargo.toml"
echo v1 > "$src/schemas/x/v.json"
printf 'const V: &str = include_str!(\n    "../../../../schemas/x/v.json"\n);\n' > "$src/cmux-tui/crates/a/src/lib.rs"
git_q -C "$src" add -A; git_q -C "$src" commit -m one
if python3 "$src/scripts/ci/check_cmux_tui_tree_inputs.py" --root "$src" 2>"$TMP/err"; then fail "an uncovered multi-line embed passed"; fi
grep -q "blob schemas/x/v.json" "$TMP/err" || fail "the check did not name the line to add: $(cat "$TMP/err")"

echo 'blob schemas/x/v.json' >> "$src/scripts/cmux-next/cmux-tui-tree-inputs.txt"
git_q -C "$src" add -A; git_q -C "$src" commit -m covered
python3 "$src/scripts/ci/check_cmux_tui_tree_inputs.py" --root "$src" >/dev/null || fail "a covered embed failed"
before=$(cd "$src" && python3 scripts/ci/cmux_tui_tree_key.py)
echo v2 > "$src/schemas/x/v.json"; git_q -C "$src" commit -am v2
after=$(cd "$src" && python3 scripts/ci/cmux_tui_tree_key.py)
[[ "$before" != "$after" ]] || fail "changing only an embedded file kept the tree key"

# A blob input a revision lacks is absent from the key, not an error.
git_q -C "$src" rm -q schemas/x/v.json; git_q -C "$src" commit -m gone
(cd "$src" && python3 scripts/ci/cmux_tui_tree_key.py >/dev/null) || fail "a missing blob input broke the key"

# 3. Only the crates the published binaries link need covering. A workspace
#    crate outside the dependency closure of the published packages (per
#    cmux-tui/Cargo.lock) never reaches a tree binary, so its embeds do not
#    belong in the key: design-tokens.json, embedded by cmux-theme-tokens, made
#    every Swift design PR rebuild the whole tree (#21785). The moment such a
#    crate joins the closure, its embed must be covered again.
lock="$TMP/lock"
git_q init "$lock"
mkdir -p "$lock/cmux-tui/crates/cmux-tui/src" "$lock/cmux-tui/crates/side/src" "$lock/cmux-tui/crates/helper/src" \
  "$lock/scripts/cmux-next" "$lock/scripts/ci" "$lock/plans/t"
cp "$ROOT/scripts/ci/check_cmux_tui_tree_inputs.py" "$lock/scripts/ci/"
printf 'tree cmux-tui\n' > "$lock/scripts/cmux-next/cmux-tui-tree-inputs.txt"
printf '[package]\nname = "cmux-tui"\n' > "$lock/cmux-tui/crates/cmux-tui/Cargo.toml"
printf '[package]\nname = "side"\n' > "$lock/cmux-tui/crates/side/Cargo.toml"
printf '[package]\nname = "helper"\n' > "$lock/cmux-tui/crates/helper/Cargo.toml"
echo '{}' > "$lock/plans/t/tokens.json"
echo 'pub fn f() {}' > "$lock/cmux-tui/crates/cmux-tui/src/lib.rs"
echo 'pub fn h() {}' > "$lock/cmux-tui/crates/helper/src/lib.rs"
printf 'const T: &str = include_str!("../../../../plans/t/tokens.json");\n' > "$lock/cmux-tui/crates/side/src/lib.rs"
write_lock() { # <cmux-tui dependencies, quoted and comma-separated>
  printf 'version = 4\n\n[[package]]\nname = "cmux-tui"\nversion = "0.1.0"\ndependencies = [%s]\n\n[[package]]\nname = "helper"\nversion = "0.1.0"\n\n[[package]]\nname = "side"\nversion = "0.1.0"\n' "$1" \
    > "$lock/cmux-tui/Cargo.lock"
}
# The tree also publishes binaries of their own workspaces (the Cloud server,
# the agent screen detector); their lockfiles must exist for anything to skip.
other_lock() { # <path> <extra package name or empty>
  mkdir -p "$lock/$(dirname "$1")"
  printf 'version = 4\n\n[[package]]\nname = "own"\nversion = "0.1.0"\n' > "$lock/$1"
  [ -z "$2" ] || printf '\n[[package]]\nname = "%s"\nversion = "0.1.0"\n' "$2" >> "$lock/$1"
}
other_lock first-party-apps/cloud/server/Cargo.lock ""
other_lock cmux-tui/bindings/examples/rust-agent-screen-detection/Cargo.lock ""
write_lock '"helper"'
git_q -C "$lock" add -A; git_q -C "$lock" commit -m closure
python3 "$lock/scripts/ci/check_cmux_tui_tree_inputs.py" --root "$lock" >/dev/null 2>"$TMP/err" \
  || fail "an embed in a crate no published binary links failed the check: $(cat "$TMP/err")"
write_lock '"helper", "side"'
git_q -C "$lock" commit -am linked
if python3 "$lock/scripts/ci/check_cmux_tui_tree_inputs.py" --root "$lock" 2>"$TMP/err"; then
  fail "an embed in a crate the published binary now links passed uncovered"
fi
grep -q "blob plans/t/tokens.json" "$TMP/err" || fail "the check did not name the linked embed: $(cat "$TMP/err")"
# A published binary of another workspace that links the crate by path (its
# own lockfile lists it) puts it back in the tree too.
write_lock '"helper"'
other_lock first-party-apps/cloud/server/Cargo.lock side
git_q -C "$lock" commit -am cloud-links-side
if python3 "$lock/scripts/ci/check_cmux_tui_tree_inputs.py" --root "$lock" 2>"$TMP/err"; then
  fail "an embed in a crate the Cloud server links passed uncovered"
fi
grep -q "blob plans/t/tokens.json" "$TMP/err" || fail "the check did not name the Cloud-linked embed: $(cat "$TMP/err")"
echo "tree-key-embeds: ok"
