#!/usr/bin/env bash
# request-nightly-next.sh promotes once its cmux-tui tree and generated page
# strings are ready. It deliberately does not inspect cmux-next CI jobs:
# nightly.yml is the build admission boundary.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
fail() { printf '%s\n' "$@" >&2; exit 1; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
bin=cmux-tui-aarch64-apple-darwin

src="$TMP/src"
git_q init "$src"
mkdir -p "$src/cmux-tui" "$src/scripts/cmux-next" "$src/scripts/ci"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$src/scripts/cmux-next/"
cp "$ROOT/scripts/cmux-next/request-nightly-next.sh" "$src/scripts/cmux-next/"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$src/scripts/ci/"
cp "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$src/scripts/cmux-next/"
echo reducer > "$src/scripts/cmux-next/build-layout-reducer-ffi.sh"
"$ROOT/scripts/cmux-next/tests/lib/tree-inputs-fixture.sh" "$src"
echo one > "$src/cmux-tui/a"
mkdir -p "$src/.github/workflows"
echo 'env: {NIGHTLY_NEXT_NOTARY_PAUSED: x}' > "$src/.github/workflows/nightly.yml"
git_q -C "$src" add -A
git_q -C "$src" commit -m one
git_q -C "$src" update-index --add --cacheinfo 160000,"$(git -C "$src" rev-parse HEAD)",ghostty
git_q -C "$src" commit -m gitlink
key() { (cd "$src" && python3 scripts/ci/cmux_tui_tree_key.py --version v2 "$1" 2>/dev/null); }

cdn="$TMP/cdn"
publish() { # <commit>: publish its tree, built by that commit
  local k; k=$(key "$1")
  mkdir -p "$cdn/tree/$k" "$cdn/$1"
  echo "build of $1" > "$cdn/tree/$k/$bin"
  sha "$cdn/tree/$k/$bin" > "$cdn/tree/$k/$bin.sha256"
  printf '{"key":"%s","commit":"%s"}\n' "$k" "$1" > "$cdn/tree/$k/source.json"
  printf '{"commit":"%s","binaries":{"%s":"%s"}}\n' "$1" "$bin" "$(sha "$cdn/tree/$k/$bin")" > "$cdn/$1/manifest.json"
}

mkdir -p "$TMP/bin"
export TEST_CDN="$cdn" TEST_LOG="$TMP/gh.log"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --proto|--retry|--retry-delay|--connect-timeout|--max-time|-w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
path="${url#https://files.cmux.com/cmux-tui/}"
[[ "$path" != "$url" && -f "$TEST_CDN/$path" ]] || exit 22
if [[ -n "$out" ]]; then cp "$TEST_CDN/$path" "$out"; else cat "$TEST_CDN/$path"; fi
STUB
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_LOG"
[[ "$1" == workflow && "$2" == run ]] || {
  echo "unexpected gh API call: $*" >&2
  exit 1
}
exit 0
STUB
chmod +x "$TMP/bin/curl" "$TMP/bin/gh"

request() {
  status=0
  : > "$TMP/gh.log"
  out=$(cd "$src" && env -u GITHUB_STEP_SUMMARY -u GITHUB_OUTPUT -u CMUX_TUI_TREE_DISPATCH \
    PATH="$TMP/bin:$PATH" bash scripts/cmux-next/request-nightly-next.sh --repo o/r "$@" 2>&1) || status=$?
}
dispatched() { grep -qx "workflow run nightly.yml --repo o/r --ref main -f promote_nightly_next_sha=$1" "$TMP/gh.log"; }

# A tree that is still building is not promoted.
echo two > "$src/cmux-tui/a"; git_q -C "$src" add -A; git_q -C "$src" commit -m "tui two"
head=$(git -C "$src" rev-parse HEAD)
request --sha "$head" --release-compile-green
[[ "$status" == 0 ]] || fail "an unpublished tree is not an error (exit $status):" "$out"
! dispatched "$head" || fail "an unpublished tree must not be promoted:" "$(cat "$TMP/gh.log")"
grep -q "not published" <<<"$out" || fail "the skip must name the unpublished tree:" "$out"

# Publication is the only source-side admission needed. The historical
# --release-compile-green flag is accepted for callers but no compile API is read.
publish "$head"
request --sha "$head" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$head" || fail "a published tree must be promoted:" "$out" "$(cat "$TMP/gh.log")"
! grep -q 'actions/workflows\|actions/runs' "$TMP/gh.log" || fail "the request must not inspect CI jobs:" "$(cat "$TMP/gh.log")"

# --tree-ready requests the exact published commit, without finding a green
# Release compile or walking a workflow-run list.
request --tree-ready "$head"
[[ "$status" == 0 ]] && dispatched "$head" || fail "--tree-ready must request its published commit:" "$out" "$(cat "$TMP/gh.log")"

# A missing notary pause gate is still a source safety refusal.
git_q -C "$src" checkout -q -b nogate "$head"
echo 'env: {}' > "$src/.github/workflows/nightly.yml"; git_q -C "$src" add -A; git_q -C "$src" commit -m nogate
nogate=$(git -C "$src" rev-parse HEAD)
request --sha "$nogate" --release-compile-green
[[ "$status" == 0 ]] || fail "a missing notary gate is not an error (exit $status):" "$out"
! dispatched "$nogate" || fail "a commit without the notary gate must not be promoted:" "$(cat "$TMP/gh.log")"
grep -q "NIGHTLY_NEXT_NOTARY_PAUSED" <<<"$out" || fail "the refusal must name the gate:" "$out"
git_q -C "$src" checkout -q --detach "$head"

# Generated strings remain a source-input check. A stale tree is skipped;
# clearing the marker lets the same commit through.
mkdir -p "$src/webviews/scripts/pages"
echo '// gen-strings' > "$src/webviews/scripts/pages/gen-strings.mjs"
echo stale > "$src/webviews/scripts/pages/STALE"
git_q -C "$src" add -A; git_q -C "$src" commit -m stale
stale=$(git -C "$src" rev-parse HEAD)
printf '#!/usr/bin/env bash\n[[ "$*" == *"gen-strings.mjs"* ]] || exit 9\n[[ ! -f scripts/pages/STALE ]] || exit 1\n' > "$TMP/bin/node"; chmod +x "$TMP/bin/node"
git_q -C "$src" checkout -q --detach "$stale"
request --sha "$stale" --release-compile-green
[[ "$status" == 0 ]] || fail "stale strings are not an error (exit $status):" "$out"
! dispatched "$stale" || fail "stale strings must not be promoted:" "$(cat "$TMP/gh.log")"
grep -q "page strings are stale" <<<"$out" || fail "the stale-string refusal must be named:" "$out"
rm "$src/webviews/scripts/pages/STALE"; git_q -C "$src" add -A; git_q -C "$src" commit -m fresh
fresh=$(git -C "$src" rev-parse HEAD)
publish "$fresh"
request --sha "$fresh" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$fresh" || fail "fresh strings must be promoted:" "$out" "$(cat "$TMP/gh.log")"

# The checkout must match the requested SHA and malformed input is a usage error.
request --sha "$head" --release-compile-green
[[ "$status" == 2 ]] || fail "a SHA other than HEAD must exit 2, got $status:" "$out"
request --sha nothex --release-compile-green
[[ "$status" == 2 ]] || fail "a malformed SHA must exit 2, got $status:" "$out"
request --sha "$fresh"
[[ "$status" == 2 ]] || fail "a SHA without the historical mode flag must exit 2, got $status:" "$out"

echo "PASS: nightly-next promotion waits for source inputs, not cmux-next CI"
