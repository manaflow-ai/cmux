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
mkdir -p "$src/scripts/lib"; cp "$ROOT/scripts/lib/rust-targets.sh" "$src/scripts/lib/"
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
mkdir -p "$chief/src" "$chief/tests" "$src/schemas/chief-profile" "$src/mux"
printf 'include!("../../../../schemas/chief-profile/generated.rs");\nconst TOOL: &str = include_str!("../../../../schemas/chief-profile/tool.json");\nconst PAGE: &str = include_str!(concat!(env!("OUT_DIR"), "/inspector.html"));\n' > "$chief/src/lib.rs"
printf 'const CASES: &str = include_str!("../../../../mux/cases.json");\n' > "$chief/tests/corpus.rs"
echo '{}' > "$src/schemas/chief-profile/tool.json"
echo 'const G: u8 = 1;' > "$src/schemas/chief-profile/generated.rs"
mkdir -p "$src/vendor/patched"
printf '[package]\nname = "patched"\n' > "$src/vendor/patched/Cargo.toml"
printf '\n[patch.crates-io]\npatched = { path = "../../../vendor/patched" }\n' >> "$chief/Cargo.toml"
echo '[]' > "$src/mux/cases.json"
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
    CMUX_NEXT_OPTCHAT_CHIEF_TARGET_DIR="$TMP/target" CMUX_NEXT_OPTCHAT_CHIEF_RESULT_FILE="$TMP/result" "$@" "$src/scripts/cmux-next/build-optchat-chief.sh" --output "$TMP/out/optchat-chief"
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

# A test target's include is not linked into the binary.
echo '[1]' > "$src/mux/cases.json"; commit test-include
keyed; expect_builds 1 "a file only a test target includes rebuilt the Chief"

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
# A file the binary compiles in from outside its crates is an input.
echo '{"v":2}' > "$src/schemas/chief-profile/tool.json"; commit schema
keyed; n=$((n + 1)); expect_builds "$n" "a change to an include_str! file outside the crates did not rebuild the Chief"
echo 'const G: u8 = 2;' > "$src/schemas/chief-profile/generated.rs"; commit generated
keyed; n=$((n + 1)); expect_builds "$n" "a change to an include! file outside the crates did not rebuild the Chief"
# A [patch] path crate is an input.
echo '# patched' >> "$src/vendor/patched/Cargo.toml"; commit patched
keyed; n=$((n + 1)); expect_builds "$n" "a change to a [patch] path crate did not rebuild the Chief"
# An include form the key cannot resolve keys by commit.
printf 'const X: &str = include_str!(concat!(env!("HOME"), "/x"));\n' > "$src/Native/OptChat/optchat-core/lib.rs"
git_q -C "$src" add -A; commit unresolvable
keyed; n=$((n + 1)); expect_builds "$n" "an unresolvable include did not build"
grep -q 'keying by commit' "$TMP/err" || fail "an unresolvable include did not fall back to the commit key: $(cat "$TMP/err")"
git_q -C "$src" rm -q Native/OptChat/optchat-core/lib.rs; commit resolvable
keyed; expect_builds "$n" "inputs equal to an earlier commit's did not reuse its binary"
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

# Unidentified compilers must not acquire a remote artifact key.
if PATH="$TMP/bin:$python_dir:/usr/bin:/bin" HOME="$TMP" python3 "$src/scripts/cmux-next/optchat-chief-input-key.py" --environment --archs x86_64 --toolchain 1.95.0 >/dev/null 2>&1; then
  fail "an unidentified compiler acquired a remote key"
fi
# The resolver key is portable; the builder adds actual tool identities.
for tool in rustup xcrun sw_vers xcodebuild xcode-select; do
  printf '#!/bin/sh\necho fixture-tool-1\n' > "$TMP/bin/$tool"
  chmod +x "$TMP/bin/$tool"
done
portable_key=$(PATH="$TMP/bin:$python_dir:/usr/bin:/bin" HOME="$TMP" python3 "$src/scripts/cmux-next/optchat-chief-input-key.py" --portable --archs x86_64 --toolchain 1.95.0)
environment_key=$(PATH="$TMP/bin:$python_dir:/usr/bin:/bin" HOME="$TMP" python3 "$src/scripts/cmux-next/optchat-chief-input-key.py" --environment --archs x86_64 --toolchain 1.95.0)
portable() {
  ARCHS_UNDER_TEST=x86_64 run CMUX_NEXT_OPTCHAT_CHIEF_INPUT_KEYED=1 CMUX_NEXT_OPTCHAT_CHIEF_INPUT_KEY="$portable_key" \
    CMUX_NEXT_OPTCHAT_CHIEF_ENVIRONMENT_KEY="$environment_key" CMUX_NEXT_OPTCHAT_CHIEF_REQUIRE_IDENTITY=1 >/dev/null 2>"$TMP/err" \
    || fail "portable cache failed: $(cat "$TMP/err")"
}
# The result file tells the workflow whether to save the entry: only a build
# that rebuilt it (a miss, or a restored entry that failed validation) saves.
expect_result() { [[ "$(cat "$TMP/result" 2>/dev/null)" == "$1" ]] || fail "$2 (result file: $(cat "$TMP/result" 2>/dev/null || echo missing), expected $1)"; }
portable; n=$((n + 1)); expect_builds "$n" "portable source key did not build once"
expect_result built "a first portable build did not report a rebuild"
portable; expect_builds "$n" "portable source key rebuilt its exact cache entry"
expect_result reused "a valid cached entry did not report reuse"
binary="$TMP/cache/inputs-$portable_key-$environment_key/x86_64/optchat-chief"
printf 'corrupt\n' >> "$binary"
portable; n=$((n + 1)); expect_builds "$n" "corrupt bytes were reused"
expect_result built "a rebuilt corrupt entry did not report a rebuild, so it would never be saved again"
mv "$binary" "$binary.target"; ln -s "$binary.target" "$binary"
portable; n=$((n + 1)); expect_builds "$n" "symlink binary was reused"
expect_result built "a rebuilt symlinked binary did not report a rebuild"
echo untouched > "$TMP/ref-target"
rm "$binary.ref"; ln -s "$TMP/ref-target" "$binary.ref"
portable; n=$((n + 1)); expect_builds "$n" "symlink provenance was reused"
expect_result built "a rebuilt symlinked provenance did not report a rebuild"
[[ "$(cat "$TMP/ref-target")" == untouched ]] || fail "rebuild followed the provenance symlink"
# A restored entry with no binary and a symlinked provenance file rebuilds
# without writing through the link to a file outside the cache.
echo untouched > "$TMP/outside-sentinel"
rm -f "$binary" "$binary.ref"; ln -s "$TMP/outside-sentinel" "$binary.ref"
portable; n=$((n + 1)); expect_builds "$n" "a missing binary did not rebuild"
[[ "$(cat "$TMP/outside-sentinel")" == untouched ]] || fail "rebuild of a missing binary wrote through the provenance symlink"
[[ ! -L "$binary.ref" ]] || fail "rebuild of a missing binary left the provenance symlink"
# A directory where the binary or its provenance belongs is repaired, not fatal.
rm -f "$binary"; mkdir "$binary"
portable; n=$((n + 1)); expect_builds "$n" "a directory in place of the binary did not rebuild"
expect_result built "a rebuilt directory binary did not report a rebuild"
[[ -f "$binary" ]] || fail "the rebuild left a directory in place of the binary"
rm -f "$binary.ref"; mkdir "$binary.ref"
portable; n=$((n + 1)); expect_builds "$n" "a directory in place of the provenance did not rebuild"
[[ -f "$binary.ref" ]] || fail "the rebuild left a directory in place of the provenance"
# A restored entry whose directories are links never sends the repair outside the cache.
entry="${binary%/*}"; outside="$TMP/outside-entry"
rm -rf "$outside"; mv "$entry" "$outside"; ln -s "$outside" "$entry"
printf 'corrupt\n' >> "$outside/optchat-chief"; cp "$outside/optchat-chief" "$TMP/outside-before"
portable; n=$((n + 1)); expect_builds "$n" "a linked entry directory was reused"
[[ ! -L "$entry" && -f "$binary" ]] || fail "the rebuild kept the linked entry directory"
cmp -s "$outside/optchat-chief" "$TMP/outside-before" || fail "the rebuild wrote through a linked entry directory"

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
# Commit-keyed fallback entries are pruned too.
for i in 1 2 3 4 5 6 7 8 9; do echo "# broken $i" >> "$src/docs/notes.md"; commit "broken $i"; keyed; done
fallbacks=$(find "$TMP/cache" -maxdepth 1 -type d | grep -cE '/[0-9a-f]{40}$' || true)
[[ "$fallbacks" -le 8 ]] || fail "the cache kept $fallbacks commit-keyed fallback entries"
echo "optchat-chief-input-cache: ok ($n builds)"
