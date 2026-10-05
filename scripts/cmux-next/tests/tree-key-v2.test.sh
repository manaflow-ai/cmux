#!/usr/bin/env bash
# CMUX-TUI-TREE-KEY-V2: the cmux-tui tree key v2 leaves out the classic
# `ghostty` gitlink (no cmux-tui binary builds from it); v1 keeps it. Trees
# published before v2 exist only under their v1 key, so `pin-cmux-tui.sh
# fetch` takes the v2 publication, else the v1 publication of the same commit.
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
[[ "$(key)" == "$v2" ]] || fail "the default key is not v2"
[[ "$v1" != "$v2" ]] || fail "v1 and v2 are equal although v1 hashes the classic gitlink"
status=0; key --version v3 >/dev/null 2>&1 || status=$?
[[ "$status" == 2 ]] || fail "an unknown key version did not exit 2 (exit $status)"

# Moving the classic gitlink changes v1 only; moving ghostty-next changes both.
other=$(git -C "$src" commit-tree "$(git -C "$src" rev-parse HEAD^{tree})" -m other)
gitlink ghostty "$other"; git_q -C "$src" commit -m "classic moves"
[[ "$(key --version v2)" == "$v2" ]] || fail "a classic gitlink move changed the v2 key"
[[ "$(key --version v1)" != "$v1" ]] || fail "a classic gitlink move did not change the v1 key"
gitlink ghostty-next "$other"; git_q -C "$src" commit -m "next moves"
[[ "$(key --version v2)" != "$v2" ]] || fail "a ghostty-next move did not change the v2 key"
v1=$(key --version v1); v2=$(key --version v2)
[[ "$(cd "$src" && bash scripts/cmux-next/pin-cmux-tui.sh key --version v1)" == "$v1" ]] || fail "pin key --version v1 differs"
[[ "$(cd "$src" && bash scripts/cmux-next/pin-cmux-tui.sh key)" == "$v2" ]] || fail "pin key is not v2"

# The CDN: tree <v1> only (published before v2).
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
publish "$v1" "daemon published under v1"
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
fetch() {
  (cd "$src" && env -u GITHUB_ACTIONS -u CI_JOB_DIR PATH="$TMP/bin:$PATH" CMUX_NEXT_TUI_ALLOW_DIRTY=1 \
    CMUX_TUI_PIN_BASE=https://cdn.test/cmux-tui CMUX_TUI_TREE_WAIT_SECONDS=0 \
    bash scripts/cmux-next/pin-cmux-tui.sh fetch 2>&1)
}
out=$(fetch) || fail "fetch through the v1 publication failed:" "$out"
grep -q "using its v1 publication $v1" <<<"$out" || fail "fetch did not report the v1 publication:" "$out"
dir="$src/cmux-tui/target/hosted/tree/$v2"
[[ "$(cat "$dir/cmux-tui")" == "daemon published under v1" ]] || fail "fetch did not store the v1 daemon under the v2 tree dir"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["key"] == sys.argv[2]' "$dir/source.json" "$v1" \
  || fail "the stored source.json does not name the v1 key it came from"

# With a v2 publication, fetch takes it and never the v1 one.
rm -rf "$dir"
publish "$v2" "daemon published under v2"
out=$(fetch) || fail "fetch of the v2 publication failed:" "$out"
if grep -q "v1 publication" <<<"$out"; then fail "fetch used v1 although v2 is published:" "$out"; fi
[[ "$(cat "$dir/cmux-tui")" == "daemon published under v2" ]] || fail "fetch did not store the v2 daemon"

printf 'tree-key-v2 tests: ok\n'
