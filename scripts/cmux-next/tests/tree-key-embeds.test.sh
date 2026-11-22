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
echo "tree-key-embeds: ok"
