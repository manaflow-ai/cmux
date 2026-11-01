#!/usr/bin/env bash
# CMUX-TUI-TREE-KEY-V2: the cmux-tui tree key v2 leaves out the classic
# `ghostty` gitlink (no cmux-tui binary builds from it); v1 keeps it. Trees
# published before docs-only filtering exist under their v2-legacy key, so
# `pin-cmux-tui.sh fetch` takes the v2 publication, else that compatibility
# publication of the same commit.
# No network: a stub curl serves the CDN from a local directory.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
fail() { printf '%s\n' "$@" >&2; exit 1; }

src="$TMP/src"
git_q init "$src"
mkdir -p "$src/cmux-tui" "$src/scripts/cmux-next" "$src/scripts/ci"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$src/scripts/cmux-next/"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$src/scripts/ci/"
cp "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$src/scripts/cmux-next/"
echo reducer > "$src/scripts/cmux-next/build-layout-reducer-ffi.sh"
"$ROOT/scripts/cmux-next/tests/lib/tree-inputs-fixture.sh" "$src"
echo one > "$src/cmux-tui/a"
git_q -C "$src" add -A
git_q -C "$src" commit -m one
base_commit=$(git -C "$src" rev-parse HEAD)
gitlink() { git_q -C "$src" update-index --add --cacheinfo 160000,"$2","$1"; }
key() { (cd "$src" && python3 scripts/ci/cmux_tui_tree_key.py "$@"); }

# A revision without the classic gitlink has a v2 key and no v1 key.
gitlink ghostty-next "$base_commit"
git_q -C "$src" commit -m next
key --version v2 >/dev/null || fail "v2 needs no classic ghostty gitlink"
if key --version v1 >/dev/null 2>&1; then fail "v1 computed without the classic ghostty gitlink"; fi

gitlink ghostty "$base_commit"
git_q -C "$src" commit -m classic
v1=$(key --version v1); v2=$(key --version v2)
legacy=$(key --version v2-legacy)
[[ "$(key)" == "$v2" ]] || fail "the default key is not v2"
[[ "$v1" != "$v2" ]] || fail "v1 and v2 are equal although v1 hashes the classic gitlink"
[[ "$legacy" == "$v2" ]] || fail "v2-legacy did not omit the classic gitlink"

# Docs-only commits do not start the artifact publisher, so their consumers
# must reuse the already-published runtime tree instead of fetching a key that
# can never be published. The v2 key excludes docs for this case, while
# v1 retains its historical full-tree behavior.
mkdir -p "$src/cmux-tui/docs"
echo prose > "$src/cmux-tui/docs/README.md"
git_q -C "$src" add cmux-tui/docs/README.md
git_q -C "$src" commit -m docs
[[ "$(key --version v2)" == "$v2" ]] || fail "a docs-only commit changed the published v2 tree key"
[[ "$(key --version v1)" != "$v1" ]] || fail "v1 unexpectedly ignored a docs-only commit"
[[ "$(key --version v2-legacy)" != "$legacy" ]] || fail "v2-legacy unexpectedly ignored a docs-only commit"
[[ "$(key --version v2-legacy)" != "$(key --version v1)" ]] || fail "v2-legacy included the classic gitlink"
# The same key survives a docs-only merge and a depth-one checkout.
docs_parent=$(git -C "$src" rev-parse HEAD)
git_q -C "$src" checkout -b docs-side
echo side > "$src/cmux-tui/docs/side.md"
git_q -C "$src" add cmux-tui/docs/side.md
git_q -C "$src" commit -m side
git_q -C "$src" checkout -b docs-main "$docs_parent"
echo main > "$src/cmux-tui/docs/main.md"
git_q -C "$src" add cmux-tui/docs/main.md
git_q -C "$src" commit -m main
git_q -C "$src" merge --no-ff docs-side -m merge-docs
[[ "$(key --version v2)" == "$v2" ]] || fail "docs-only merge changed v2"
git_q clone --depth=1 "file://$src" "$TMP/shallow"
[[ "$(cd "$TMP/shallow" && python3 scripts/ci/cmux_tui_tree_key.py)" == "$v2" ]] || fail "depth-one key changed"
# A mixed code/docs change must still invalidate the runtime key.
echo code >> "$src/cmux-tui/a"
echo mixed >> "$src/cmux-tui/docs/README.md"
git_q -C "$src" add cmux-tui
git_q -C "$src" commit -m mixed
[[ "$(key --version v2)" != "$v2" ]] || fail "mixed code/docs reused old key"
v2=$(key --version v2)
status=0; key --version v3 >/dev/null 2>&1 || status=$?
[[ "$status" == 2 ]] || fail "an unknown key version did not exit 2 (exit $status)"

# Moving the classic gitlink changes v1 only; moving ghostty-next changes both.
# The test's own identity, like git_q: a CI runner has no global one.
other=$(git -c user.name=t -c user.email=t@example.com -C "$src" commit-tree "$(git -C "$src" rev-parse HEAD^{tree})" -m other)
gitlink ghostty "$other"; git_q -C "$src" commit -m "classic moves"
[[ "$(key --version v2)" == "$v2" ]] || fail "a classic gitlink move changed the v2 key"
[[ "$(key --version v1)" != "$v1" ]] || fail "a classic gitlink move did not change the v1 key"
gitlink ghostty-next "$other"; git_q -C "$src" commit -m "next moves"
[[ "$(key --version v2)" != "$v2" ]] || fail "a ghostty-next move did not change the v2 key"
v1=$(key --version v1); v2=$(key --version v2)
[[ "$(cd "$src" && bash scripts/cmux-next/pin-cmux-tui.sh key --version v1)" == "$v1" ]] || fail "pin key --version v1 differs"
[[ "$(cd "$src" && bash scripts/cmux-next/pin-cmux-tui.sh key)" == "$v2" ]] || fail "pin key is not v2"

# The CDN: tree <v2-legacy> only (published before docs-only filtering).
cdn="$TMP/cdn"
publish() { # <key> <bytes>
  mkdir -p "$cdn/tree/$1"
  printf '%s' "$2" > "$cdn/tree/$1/cmux-tui-aarch64-apple-darwin"
  printf '%s  cmux-tui-aarch64-apple-darwin\n' "$(shasum -a 256 "$cdn/tree/$1/cmux-tui-aarch64-apple-darwin" | awk '{print $1}')" \
    > "$cdn/tree/$1/cmux-tui-aarch64-apple-darwin.sha256"
  printf '{"key": "%s", "commit": "%s"}\n' "$1" "$base_commit" > "$cdn/tree/$1/source.json"
}
mkdir -p "$cdn/$base_commit"
printf '{"binaries": {}}\n' > "$cdn/$base_commit/manifest.json"
legacy=$(key --version v2-legacy)
publish "$legacy" "daemon published under v2-legacy"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
# Serves https://cdn.test/cmux-tui/<path> from $cdn; any other URL fails.
out="" url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    --proto|--retry|--retry-delay|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
path="\${url%%\?*}"
path="\${path#https://cdn.test/cmux-tui/}"
[[ "\$path" != "\$url" && -f "$cdn/\$path" ]] || exit 22
if [[ -n "\$out" ]]; then cp "$cdn/\$path" "\$out"; else cat "$cdn/\$path"; fi
STUB
chmod +x "$TMP/bin/curl"
# The stub CDN publishes the macOS arm64 daemon only. Pin that target: on a Linux runner
# pin-cmux-tui.sh would otherwise ask for x86_64-unknown-linux-musl, which these trees lack.
fetch() {
  (cd "$src" && env -u GITHUB_ACTIONS -u CI_JOB_DIR PATH="$TMP/bin:$PATH" CMUX_NEXT_TUI_ALLOW_DIRTY=1 \
    CMUX_TUI_PIN_BASE=https://cdn.test/cmux-tui CMUX_TUI_TREE_WAIT_SECONDS=0 CMUX_TUI_TREE_TARGET=aarch64-apple-darwin \
    bash scripts/cmux-next/pin-cmux-tui.sh fetch 2>&1)
}
out=$(fetch) || fail "fetch through the compatibility publication failed:" "$out"
grep -q "using its compatibility publication $legacy" <<<"$out" || fail "fetch did not report the v2-legacy publication:" "$out"
dir="$src/cmux-tui/target/hosted/tree/$v2"
[[ "$(cat "$dir/cmux-tui")" == "daemon published under v2-legacy" ]] || fail "fetch did not store the compatibility daemon under the v2 tree dir"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["key"] == sys.argv[2]' "$dir/source.json" "$legacy" \
  || fail "the stored source.json does not name the compatibility key it came from"
# B2 evidence: the log names the key actually fetched, and the cache dir (named
# by the v2 key) records it, so a cached compatibility fallback cannot pass for v2.
grep -qxF "fetched cmux-tui tree $legacy (compatibility fallback)" <<<"$out" || fail "fetch did not name the compatibility fallback key it fetched:" "$out"
[[ "$(cat "$dir/fetched-key" 2>/dev/null)" == "$legacy compatibility" ]] || fail "the cache dir does not record the compatibility key it was fetched from"
out=$(fetch) || fail "the cached fetch failed:" "$out"
grep -qxF "cmux-tui tree $v2 already present, fetched from $legacy (compatibility fallback)" <<<"$out" \
  || fail "a cache hit hid that the binary came from the compatibility fallback:" "$out"

# An immutable publication predating v2 must remain readable as well.
rm -rf "$dir" "$cdn/tree/$legacy"
publish "$v1" "daemon published under v1"
out=$(fetch) || fail "fetch through the v1 publication failed:" "$out"
[[ "$(cat "$dir/cmux-tui")" == "daemon published under v1" ]] || fail "lost v1 fallback"
[[ "$(cat "$dir/fetched-key")" == "$v1 compatibility" ]] || fail "v1 source was hidden"
rm -rf "$cdn/tree/$v1"
publish "$legacy" "daemon published under v2-legacy"

# With a v2 publication, fetch takes it and never the v1 one.
rm -rf "$dir"
publish "$v2" "daemon published under v2"
out=$(fetch) || fail "fetch of the v2 publication failed:" "$out"
if grep -q "v2-legacy publication" <<<"$out"; then fail "fetch used compatibility publication although v2 is published:" "$out"; fi
[[ "$(cat "$dir/cmux-tui")" == "daemon published under v2" ]] || fail "fetch did not store the v2 daemon"
grep -qxF "fetched cmux-tui tree $v2 (v2)" <<<"$out" || fail "fetch did not name the v2 key it fetched:" "$out"
out=$(fetch) || fail "the cached v2 fetch failed:" "$out"
grep -qxF "cmux-tui tree $v2 already present, fetched from $v2 (v2)" <<<"$out" || fail "a v2 cache hit did not say v2:" "$out"
# A cache from before the record says nothing about its source: fetch again.
rm -f "$dir/fetched-key"
out=$(fetch) || fail "fetch over an unrecorded cache failed:" "$out"
grep -qxF "fetched cmux-tui tree $v2 (v2)" <<<"$out" || fail "an unrecorded cache was trusted instead of fetched again:" "$out"

# The cmux-next gate: `wait` reports a published tree and superseded=false.
: > "$TMP/gh-output"
out=$(cd "$src" && env -u GITHUB_ACTIONS -u CI_JOB_DIR PATH="$TMP/bin:$PATH" CMUX_NEXT_TUI_ALLOW_DIRTY=1 \
  GITHUB_OUTPUT="$TMP/gh-output" CMUX_TUI_PIN_BASE=https://cdn.test/cmux-tui CMUX_TUI_TREE_WAIT_SECONDS=0 \
  bash scripts/cmux-next/pin-cmux-tui.sh wait 2>&1) || fail "wait for a published tree failed:" "$out"
grep -qxF "cmux-tui tree $v2 is published: $v2 (v2)" <<<"$out" || fail "wait did not name the published tree:" "$out"
grep -qxF "superseded=false" "$TMP/gh-output" || fail "wait did not write superseded=false"

# resolve-commit names the key it resolved on stderr; stdout is the commit only.
sha=$(awk '{print $1}' "$cdn/tree/$v2/cmux-tui-aarch64-apple-darwin.sha256")
printf '{"binaries": {"cmux-tui-aarch64-apple-darwin": "%s"}}\n' "$sha" > "$cdn/$base_commit/manifest.json"
resolve() {
  (cd "$src" && env -u GITHUB_ACTIONS -u CI_JOB_DIR PATH="$TMP/bin:$PATH" CMUX_NEXT_TUI_ALLOW_DIRTY=1 \
    CMUX_TUI_PIN_BASE=https://cdn.test/cmux-tui CMUX_TUI_TREE_WAIT_SECONDS=0 \
    bash scripts/cmux-next/pin-cmux-tui.sh resolve-commit 2>"$TMP/resolve.err")
}
commit=$(resolve) || fail "resolve-commit failed:" "$(cat "$TMP/resolve.err")"
[[ "$commit" == "$base_commit" ]] || fail "resolve-commit printed '$commit', not only the commit"
grep -qxF "resolved cmux-tui tree $v2 (v2)" "$TMP/resolve.err" || fail "resolve-commit did not name the v2 key:" "$(cat "$TMP/resolve.err")"
rm -rf "$cdn/tree/$v2"
sha=$(awk '{print $1}' "$cdn/tree/$legacy/cmux-tui-aarch64-apple-darwin.sha256")
printf '{"binaries": {"cmux-tui-aarch64-apple-darwin": "%s"}}\n' "$sha" > "$cdn/$base_commit/manifest.json"
commit=$(resolve) || fail "resolve-commit through v1 failed:" "$(cat "$TMP/resolve.err")"
grep -qxF "resolved cmux-tui tree $legacy (compatibility fallback)" "$TMP/resolve.err" || fail "resolve-commit did not name the compatibility fallback:" "$(cat "$TMP/resolve.err")"

# MACOS-CROSS-COMPILE-ON-LINUX: the Mac and the Linux builder give
# byte-different macOS binaries, so the builder switch and the Linux recipe
# are key inputs. A fallback to the other builder never reuses a tree.
before=$(key --version v2)
mkdir -p "$src/scripts/ci/macos-stubs"
printf 'linux\n' > "$src/scripts/ci/cmux-tui-darwin-builder"
git_q -C "$src" add scripts/ci/cmux-tui-darwin-builder
git_q -C "$src" commit -m builder
[[ "$(key --version v2)" != "$before" ]] || fail "switching the macOS builder kept the tree key"
before=$(key --version v2)
echo "changed stub" > "$src/scripts/ci/macos-stubs/Security.tbd"
git_q -C "$src" add scripts/ci/macos-stubs/Security.tbd
git_q -C "$src" commit -m stubs
[[ "$(key --version v2)" != "$before" ]] || fail "a framework stub change kept the tree key"

# A revision the checkout does not have fails at once, in a partial clone too:
# one lazy promisor fetch per input pegged a Mac for 19 minutes on a
# placeholder sha (2026-10-20). The promisor's upload-pack records any fetch.
cat > "$TMP/upload-pack" <<EOF
#!/bin/sh
touch "$TMP/lazy-fetched"
exec git-upload-pack "\$@"
EOF
chmod +x "$TMP/upload-pack"
git_q -c uploadpack.allowFilter=true clone --filter=blob:none --no-checkout "file://$src" "$TMP/partial"
git_q -C "$TMP/partial" config remote.origin.uploadpack "$TMP/upload-pack"
git_q -C "$TMP/partial" config uploadpack.allowFilter true
mkdir -p "$TMP/partial/scripts/ci" "$TMP/partial/scripts/cmux-next"
cp "$src/scripts/ci/cmux_tui_tree_key.py" "$TMP/partial/scripts/ci/"
cp "$src/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$TMP/partial/scripts/cmux-next/"
rm -f "$TMP/lazy-fetched"
missing=$(printf 'a%.0s' {1..40})
status=0
out=$(cd "$TMP/partial" && python3 scripts/ci/cmux_tui_tree_key.py --version v1 "$missing" 2>&1) || status=$?
[[ ! -e "$TMP/lazy-fetched" ]] || fail "a missing revision fetched from the promisor remote"
[[ "$status" == 1 && "$out" == *"$missing is not a commit in this checkout"* ]] \
  || fail "a missing revision did not fail with its own error (exit $status): $out"
[[ "$(cd "$TMP/partial" && python3 scripts/ci/cmux_tui_tree_key.py --version v2 HEAD)" == "$(key --version v2)" ]] \
  || fail "a partial clone computed a different key for a present revision"

printf 'tree-key-v2 tests: ok\n'
