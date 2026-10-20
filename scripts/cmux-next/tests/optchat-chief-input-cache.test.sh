#!/usr/bin/env bash
# With CMUX_NEXT_OPTCHAT_CHIEF_INPUT_KEYED=1, build-optchat-chief.sh reuses the
# binary of an earlier commit whose Chief inputs were the same, and rebuilds
# when any input changed: a local crate in its path-dependency closure (also
# through `workspace = true`), the workspace manifest it inherits from, a
# regenerated tracked file (the inspector page) or the architectures. Without
# the variable every commit builds, as before. A nightly-next build rebuilt the
# Chief on every push (about 90 s of the warm build slot).
# Fake cargo and rustup stand in for the toolchain.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf '%s\n' "$@" >&2; exit 1; }
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
python_dir=$(dirname "$(command -v python3)")
python3 -c 'import tomllib' 2>/dev/null || { echo "optchat-chief-input-cache: skipped (python3 has no tomllib)"; exit 0; }

src="$TMP/src"
chief="$src/Native/OptChat/optchat-chief"
mkdir -p "$src/scripts/cmux-next" "$chief/inspector" "$src/Native/OptChat/optchat-core" \
  "$src/cmux-tui/crates/cmux-chief" "$src/cmux-tui/crates/unrelated" "$src/docs" "$TMP/bin"
cp "$ROOT/scripts/cmux-next/build-optchat-chief.sh" "$ROOT/scripts/cmux-next/optchat-chief-input-key.py" "$src/scripts/cmux-next/"
cat > "$chief/Cargo.toml" <<'EOF'
[package]
name = "optchat-chief"

[workspace]

[dependencies]
optchat-core = { path = "../optchat-core" }
cmux-chief = { path = "../../../cmux-tui/crates/cmux-chief" }

[dev-dependencies]
unrelated = { path = "../../../cmux-tui/crates/unrelated" }
EOF
echo 'page one' > "$chief/inspector/index.html"
printf '[package]\nname = "optchat-core"\n' > "$src/Native/OptChat/optchat-core/Cargo.toml"
cat > "$src/cmux-tui/Cargo.toml" <<'EOF'
[workspace]
members = ["crates/*"]

[workspace.dependencies]
cmux-server-core = { path = "crates/cmux-server-core" }
EOF
mkdir -p "$src/cmux-tui/crates/cmux-server-core/src"
printf '[package]\nname = "cmux-server-core"\n' > "$src/cmux-tui/crates/cmux-server-core/Cargo.toml"
printf '[package]\nname = "cmux-chief"\n\n[dependencies]\ncmux-server-core = { workspace = true }\n' > "$src/cmux-tui/crates/cmux-chief/Cargo.toml"
printf '[package]\nname = "unrelated"\n' > "$src/cmux-tui/crates/unrelated/Cargo.toml"
printf '[toolchain]\nchannel = "1.95.0"\n' > "$src/cmux-tui/rust-toolchain.toml"
echo one > "$src/docs/notes.md"
git_q init "$src"; git_q -C "$src" add -A; git_q -C "$src" commit -m one

cat > "$TMP/bin/cargo" <<'EOF'
#!/usr/bin/env bash
target=""
while [[ $# -gt 0 ]]; do
  case "$1" in --target) target="$2"; shift ;; esac
  shift
done
mkdir -p "$CARGO_TARGET_DIR/$target/release"
printf '#!/bin/sh\necho %s\n' "$OPTCHAT_BUILD_COMMIT" > "$CARGO_TARGET_DIR/$target/release/optchat-chief"
chmod 755 "$CARGO_TARGET_DIR/$target/release/optchat-chief"
echo "$OPTCHAT_BUILD_COMMIT" >> "$FAKE_CARGO_LOG"
EOF
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/rustup"
printf '#!/bin/sh\necho "$@" >&2\nexit 1\n' > "$TMP/bin/lipo"
chmod 755 "$TMP/bin/cargo" "$TMP/bin/rustup" "$TMP/bin/lipo"
: > "$TMP/cargo.log"

run() {
  env -i PATH="$TMP/bin:$python_dir:/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" CI=1 FAKE_CARGO_LOG="$TMP/cargo.log" \
    CMUX_NEXT_OPTCHAT_CHIEF_ARCHS="${ARCHS_UNDER_TEST:-arm64}" CMUX_NEXT_OPTCHAT_CHIEF_CACHE="$TMP/cache" \
    CMUX_NEXT_OPTCHAT_CHIEF_TARGET_DIR="$TMP/target" "$@" "$src/scripts/cmux-next/build-optchat-chief.sh" --output "$TMP/out/optchat-chief"
}
builds() { grep -c . "$TMP/cargo.log" || true; }
keyed() { run CMUX_NEXT_OPTCHAT_CHIEF_INPUT_KEYED=1 >/dev/null 2>"$TMP/err" || fail "keyed build failed: $(cat "$TMP/err")"; }
commit() { git_q -C "$src" commit -am "$1"; }
expect_builds() { [[ "$(builds)" == "$1" ]] || fail "$2 (cargo ran $(builds) times, expected $1)"; }

keyed; expect_builds 1 "the first keyed build did not run cargo"
first=$(git -C "$src" rev-parse --short=11 HEAD)

# A commit that changes nothing the Chief reads reuses the binary.
echo two > "$src/docs/notes.md"; commit two
keyed; expect_builds 1 "a docs-only commit rebuilt the Chief"
[[ "$("$TMP/out/optchat-chief")" == "$first" ]] || fail "the reused binary is not the one built at $first"
# A dev-dependency is not linked into the release binary.
echo '# x' >> "$src/cmux-tui/crates/unrelated/Cargo.toml"; commit three
keyed; expect_builds 1 "a dev-dependency change rebuilt the Chief"

# Without the variable the commit keys the cache, as before.
run >/dev/null 2>"$TMP/err" || fail "unkeyed build failed: $(cat "$TMP/err")"
expect_builds 2 "an unkeyed build of a new commit did not run cargo"

# Every input change rebuilds.
n=2
for change in \
    "Native/OptChat/optchat-core/Cargo.toml" \
    "cmux-tui/crates/cmux-server-core/Cargo.toml" \
    "cmux-tui/Cargo.toml" \
    "Native/OptChat/optchat-chief/Cargo.toml"; do
  echo '# changed' >> "$src/$change"; commit "change $change"
  keyed; n=$((n + 1)); expect_builds "$n" "a change to $change did not rebuild the Chief"
  keyed; expect_builds "$n" "a second build of the same inputs ($change) rebuilt the Chief"
done
# A new file in a crate is an input.
echo 'pub fn f() {}' > "$src/cmux-tui/crates/cmux-server-core/src/lib.rs"; git_q -C "$src" add -A; commit "new file"
keyed; n=$((n + 1)); expect_builds "$n" "a new source file did not rebuild the Chief"
# build-web-bundles.sh rewrites the tracked inspector page in place: the
# working-tree content is the input, not the committed one.
echo 'page two' > "$chief/inspector/index.html"
keyed; n=$((n + 1)); expect_builds "$n" "a regenerated inspector page did not rebuild the Chief"
git -C "$src" checkout -q -- Native/OptChat/optchat-chief/inspector/index.html
keyed; expect_builds "$n" "restoring the committed page did not reuse its binary"
# Another architecture set is another binary.
ARCHS_UNDER_TEST=x86_64 keyed; n=$((n + 1)); expect_builds "$n" "another architecture reused the arm64 binary"

# Only the 8 most recently used input-keyed entries stay.
entries=$(find "$TMP/cache" -maxdepth 1 -name 'inputs-*' | grep -c .)
[[ "$entries" -le 8 ]] || fail "the input-keyed cache kept $entries entries"
for i in 1 2 3 4 5 6 7 8 9; do
  echo "# prune $i" >> "$src/Native/OptChat/optchat-core/Cargo.toml"; commit "prune $i"; keyed
done
entries=$(find "$TMP/cache" -maxdepth 1 -name 'inputs-*' | grep -c .)
[[ "$entries" -eq 8 ]] || fail "the input-keyed cache kept $entries entries, expected 8"

# An unreadable manifest falls back to the commit key (and still builds).
echo 'not toml [' > "$src/Native/OptChat/optchat-core/Cargo.toml"; commit broken
keyed; n=$(builds)
grep -q 'keying by commit' "$TMP/err" || fail "an unreadable manifest did not fall back to the commit key: $(cat "$TMP/err")"
[[ -x "$TMP/cache/$(git -C "$src" rev-parse HEAD)/arm64/optchat-chief" ]] || fail "the fallback build is not in the commit-keyed cache"
echo "optchat-chief-input-cache: ok ($n builds)"
