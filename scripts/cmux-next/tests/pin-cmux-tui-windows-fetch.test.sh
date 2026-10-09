#!/usr/bin/env bash
# pin-cmux-tui.sh fetch on Windows x86_64 (Git Bash) takes
# cmux-tui-x86_64-pc-windows-gnu.exe from the tree, checks its published
# .sha256, and writes it as <tree>/x86_64-pc-windows-gnu/cmux-tui.exe (no
# companions: the Windows daemon has no app, cloud or browser host).
# A tree published before the Windows target fails at once instead of waiting.
# A binary whose bytes differ from the published .sha256 is refused.
# CMUX_TUI_TREE_TARGET=x86_64-pc-windows-gnu fetches it from any host.
# No network: a curl shim serves the CDN from files; a uname shim plays the host.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }
fail() { printf '%s\n' "$1" >&2; exit 1; }

git_q init "$TMP/src"
mkdir -p "$TMP/src/cmux-tui" "$TMP/src/scripts/cmux-next" "$TMP/src/scripts/ci"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$TMP/src/scripts/cmux-next/"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$TMP/src/scripts/ci/"
cp "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$TMP/src/scripts/cmux-next/"
echo reducer > "$TMP/src/scripts/cmux-next/build-layout-reducer-ffi.sh"
"$ROOT/scripts/cmux-next/tests/lib/tree-inputs-fixture.sh" "$TMP/src"
echo one > "$TMP/src/cmux-tui/a"
echo 'target/' > "$TMP/src/cmux-tui/.gitignore"
git_q -C "$TMP/src" add -A
git_q -C "$TMP/src" commit -m one
git_q -C "$TMP/src" branch -M feat-cmux-next
git_q clone --bare "$TMP/src" "$TMP/origin.git"
git_q -C "$TMP/src" remote add origin "$TMP/origin.git"
git_q -C "$TMP/src" fetch origin
sha=$(git -C "$TMP/src" rev-parse HEAD)
key=$(cd "$TMP/src" && bash scripts/cmux-next/pin-cmux-tui.sh key)
win="$TMP/src/cmux-tui/target/hosted/tree/$key/x86_64-pc-windows-gnu"

mkdir -p "$TMP/bin" "$TMP/cdn/tree/$key" "$TMP/cdn/$sha"
real_curl=$(command -v curl)
cat > "$TMP/bin/curl" <<SHIM
#!/usr/bin/env bash
out=""; url=""; args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do
  case "\${args[i]}" in
    -o) out="\${args[i+1]}" ;;
    https://cdn.test/*) url="\${args[i]}" ;;
  esac
done
if [[ -z "\$url" ]]; then exec "$real_curl" "\$@"; fi
path="$TMP/cdn/\${url#https://cdn.test/cmux-tui/}"; path="\${path%%\\?*}"
[[ -f "\$path" ]] || exit 22
if [[ -n "\$out" ]]; then cp "\$path" "\$out"; else cat "\$path"; fi
SHIM
cat > "$TMP/bin/uname" <<'SHIM'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo "${FAKE_UNAME_S:?}" ;;
  -m) echo "${FAKE_UNAME_M:?}" ;;
  *) echo "${FAKE_UNAME_S:?}" ;;
esac
SHIM
chmod +x "$TMP/bin/curl" "$TMP/bin/uname"

publish() { # <name> <bytes>: commit-addressed and tree objects
  printf '%s' "$2" > "$TMP/cdn/$sha/$1"
  printf '%s' "$2" > "$TMP/cdn/tree/$key/$1"
  printf '%s  %s\n' "$(sha256 "$TMP/cdn/tree/$key/$1")" "$1" > "$TMP/cdn/tree/$key/$1.sha256"
  printf '{"key":"%s","commit":"%s"}\n' "$key" "$sha" > "$TMP/cdn/tree/$key/source.json"
}
run() { # <uname -s> <uname -m> <command...>
  local s="$1" m="$2"; shift 2
  (cd "$TMP/src" && env -u GITHUB_ACTIONS -u CI_JOB_DIR -u CMUX_TUI_TREE_TARGET PATH="$TMP/bin:$PATH" \
    FAKE_UNAME_S="$s" FAKE_UNAME_M="$m" CMUX_TUI_PIN_BASE=https://cdn.test/cmux-tui \
    CMUX_TUI_TREE_WAIT_SECONDS=60 CMUX_TUI_TREE_POLL_SECONDS=1 ${EXTRA_ENV:+"$EXTRA_ENV"} \
    bash scripts/cmux-next/pin-cmux-tui.sh "$@" 2>&1)
}
WINHOST="MINGW64_NT-10.0-20348 x86_64"

# A tree published before the Windows target: fail at once, naming it.
publish cmux-tui-aarch64-apple-darwin mac-daemon
status=0; started=$(date +%s)
out=$(run $WINHOST fetch) || status=$?
[[ "$status" != 0 ]] || fail "fetch on Windows succeeded for a tree without Windows:
$out"
(( $(date +%s) - started < 30 )) || fail "fetch on Windows waited for a target the tree will never have:
$out"
grep -q 'x86_64-pc-windows-gnu' <<<"$out" || fail "the refusal does not name the Windows target:
$out"

# A Windows binary whose bytes differ from its published .sha256 is refused.
publish cmux-tui-x86_64-pc-windows-gnu.exe win-daemon
printf 'tampered' > "$TMP/cdn/tree/$key/cmux-tui-x86_64-pc-windows-gnu.exe"
status=0; out=$(run $WINHOST fetch) || status=$?
[[ "$status" != 0 ]] || fail "fetch accepted a Windows binary that does not match its .sha256:
$out"
[[ ! -e "$win/cmux-tui.exe" ]] || fail "a refused binary was left at $win/cmux-tui.exe"

# The published Windows binary: fetched as cmux-tui.exe with its sha256 record.
publish cmux-tui-x86_64-pc-windows-gnu.exe win-daemon
out=$(run $WINHOST fetch) || fail "fetch on Windows failed:
$out"
bin=$(run $WINHOST path | tail -n 1)
[[ "$bin" == "$win/cmux-tui.exe" ]] || fail "Windows path is $bin, not $win/cmux-tui.exe"
[[ "$(cat "$bin")" == win-daemon ]] || fail "Windows fetched $(cat "$bin" 2>/dev/null)"
[[ "$(cat "$win/cmux-tui.exe.sha256")" == "$(sha256 "$bin")" ]] || fail "no sha256 record beside $bin"
[[ ! -e "$win/cmux-app-host.sha256" ]] || fail "fetch looked for a Windows app host"

# A second fetch reuses the checked copy.
out=$(run $WINHOST fetch) || fail "second fetch failed:
$out"
grep -q 'already present' <<<"$out" || fail "second fetch did not reuse the copy:
$out"

# From macOS with CMUX_TUI_TREE_TARGET (a cross bundle).
rm -rf "$win"
out=$(EXTRA_ENV=CMUX_TUI_TREE_TARGET=x86_64-pc-windows-gnu run Darwin arm64 fetch) || fail "cross fetch failed:
$out"
[[ "$(cat "$win/cmux-tui.exe")" == win-daemon ]] || fail "cross fetch did not write $win/cmux-tui.exe:
$out"

echo "pin-cmux-tui-windows-fetch.test.sh: ok"
