#!/usr/bin/env bash
# pin-cmux-tui.sh fallback-key: fleet suite steps (run-swift-testing-suites.sh)
# test a head whose own tree is not published against the newest published
# tree when the head changes no tree input. Fleet steps check out the ref
# shallowly from the repository URL, with no origin remote and no
# origin/feat-cmux-next ref; after #19985 and #19987 landed every such step
# still skipped the live-daemon suites (steps 1d2d7a3f2e5c, f6276fe17989).
# No network: a stub curl serves the CDN and origin is a local repository.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=feat-cmux-next -c protocol.file.allow=always "$@" >/dev/null 2>&1; }
fail() { printf '%s\n' "$@" >&2; exit 1; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
bin=cmux-tui-aarch64-apple-darwin

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
git_q -C "$src" update-index --add --cacheinfo 160000,"$(git -C "$src" rev-parse HEAD)",ghostty
git_q -C "$src" commit -m gitlink
commit() { # <file> <content> <message> -> commit sha
  echo "$2" > "$src/$1"; git_q -C "$src" add -A; git_q -C "$src" commit -m "$3"; git -C "$src" rev-parse HEAD; }
published=$(commit cmux-tui/a two "tui two (published)")
app=$(commit App.swift app "app only (tree not published yet)")
git_q -C "$src" checkout -b pr
pr=$(commit App.swift pr "a pull request head that changes no tree input")
git_q -C "$src" checkout feat-cmux-next
tui=$(commit cmux-tui/a three "tui three (tree not published yet)")
key() { (cd "$src" && python3 scripts/ci/cmux_tui_tree_key.py --version v2 "$1" 2>/dev/null); }

cdn="$TMP/cdn"
k=$(key "$published")
mkdir -p "$cdn/tree/$k" "$cdn/$published"
echo "build of $published" > "$cdn/tree/$k/$bin"
sha "$cdn/tree/$k/$bin" > "$cdn/tree/$k/$bin.sha256"
printf '{"key": "%s", "commit": "%s"}\n' "$k" "$published" > "$cdn/tree/$k/source.json"
printf '{"commit": "%s", "binaries": {"%s": "%s"}}\n' "$published" "$bin" "$(sha "$cdn/tree/$k/$bin")" > "$cdn/$published/manifest.json"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
out="" url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    --proto|--retry|--retry-delay|--connect-timeout|--max-time|-w) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
path="\${url#https://files.cmux.com/cmux-tui/}"; path="\${path%%\?*}"
[[ "\$path" != "\$url" && -f "$cdn/\$path" ]] || exit 22
if [[ -n "\$out" ]]; then cp "$cdn/\$path" "\$out"; else cat "$cdn/\$path"; fi
STUB
chmod +x "$TMP/bin/curl"

fallback() { # <commit>: a fleet-style checkout -> $out, $status
  # As the fleet worker makes it: git init, then a depth-1 fetch of the commit
  # from the repository URL, so no origin remote and no branch refs.
  local dir="$TMP/checkout-$1"
  git_q init "$dir"
  git_q -C "$dir" fetch --depth 1 "file://$src" "$1"
  git_q -C "$dir" checkout --detach FETCH_HEAD
  status=0
  out=$(cd "$dir" && env -u GITHUB_STEP_SUMMARY -u GITHUB_OUTPUT PATH="$TMP/bin:$PATH" \
    CMUX_TUI_TREE_FALLBACK_REMOTE="file://$src" GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
    bash scripts/cmux-next/pin-cmux-tui.sh fallback-key 2>"$TMP/err") || status=$?
  err=$(cat "$TMP/err")
}

fallback "$app"
[[ "$status" == 0 && "$out" == "$k" ]] || fail "a base commit that changes no tree input must fall back to $k (exit $status):" "$out" "$err"
fallback "$pr"
[[ "$status" == 0 && "$out" == "$k" ]] || fail "a PR head that changes no tree input must fall back to $k (exit $status):" "$out" "$err"
fallback "$tui"
[[ "$status" != 0 && -z "$out" ]] || fail "a commit that changes cmux-tui must get no fallback, got:" "$out"
grep -q "changes a cmux-tui tree input" <<<"$err" || fail "the refusal must say why:" "$err"
echo "pin-cmux-tui-fallback-key: ok"
