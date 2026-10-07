#!/usr/bin/env bash
# pin-cmux-tui.sh maps the host (uname -s / uname -m) to its cmux-tui tree target:
#   Linux x86_64 or amd64  -> x86_64-unknown-linux-musl
#   Linux aarch64 or arm64 -> aarch64-unknown-linux-musl
#   macOS (any machine)    -> aarch64-apple-darwin, the gate target (no target subdirectory)
#   anything else          -> exit 2, naming CMUX_TUI_TREE_TARGET
# and CMUX_TUI_TREE_TARGET overrides the host. `path` prints the tree directory, which
# names the target, so this needs no network. A uname shim plays the host.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
fail() { printf '%s\n' "$@" >&2; exit 1; }

src="$TMP/src"
git_q init "$src"
mkdir -p "$src/cmux-tui" "$src/scripts/cmux-next" "$src/scripts/ci" "$TMP/bin"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$src/scripts/cmux-next/"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$src/scripts/ci/"
cp "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$src/scripts/cmux-next/"
echo reducer > "$src/scripts/cmux-next/build-layout-reducer-ffi.sh"
echo one > "$src/cmux-tui/a"
git_q -C "$src" add -A
git_q -C "$src" commit -m one
key=$(cd "$src" && python3 scripts/ci/cmux_tui_tree_key.py 2>/dev/null)
tree="$src/cmux-tui/target/hosted/tree/$key"

cat > "$TMP/bin/uname" <<'SHIM'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo "${FAKE_UNAME_S:?}" ;;
  -m) echo "${FAKE_UNAME_M:?}" ;;
  *) echo "${FAKE_UNAME_S:?}" ;;
esac
SHIM
chmod +x "$TMP/bin/uname"

path_on() { # <uname -s> <uname -m> [NAME=VALUE...]: pin-cmux-tui.sh path on that host
  local s="$1" m="$2"; shift 2
  (cd "$src" && env -u GITHUB_ACTIONS -u CI_JOB_DIR -u CMUX_TUI_TREE_TARGET -u CMUX_NEXT_TUI_MODE \
    PATH="$TMP/bin:$PATH" FAKE_UNAME_S="$s" FAKE_UNAME_M="$m" "$@" \
    bash scripts/cmux-next/pin-cmux-tui.sh path 2>"$TMP/err")
}

expect() { # <uname -s> <uname -m> <expected path>
  local out
  out=$(path_on "$1" "$2") || fail "$1/$2: path failed:" "$(cat "$TMP/err")"
  [[ "$out" == "$3" ]] || fail "$1/$2: expected $3" "got $out"
}

expect Linux x86_64 "$tree/x86_64-unknown-linux-musl/cmux-tui"
expect Linux amd64 "$tree/x86_64-unknown-linux-musl/cmux-tui"
expect Linux aarch64 "$tree/aarch64-unknown-linux-musl/cmux-tui"
expect Linux arm64 "$tree/aarch64-unknown-linux-musl/cmux-tui"
expect Darwin arm64 "$tree/cmux-tui"
expect Darwin x86_64 "$tree/cmux-tui"

status=0; path_on FreeBSD amd64 >/dev/null || status=$?
[[ "$status" == 2 ]] || fail "an unknown host did not exit 2 (exit $status):" "$(cat "$TMP/err")"
grep -q "set CMUX_TUI_TREE_TARGET" "$TMP/err" || fail "an unknown host did not name CMUX_TUI_TREE_TARGET:" "$(cat "$TMP/err")"

out=$(path_on Linux x86_64 CMUX_TUI_TREE_TARGET=aarch64-apple-darwin) || fail "override: path failed:" "$out"
[[ "$out" == "$tree/cmux-tui" ]] || fail "CMUX_TUI_TREE_TARGET did not override the Linux host" "got $out"

echo "pin-cmux-tui host target tests: ok"
