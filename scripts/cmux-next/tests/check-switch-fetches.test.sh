#!/usr/bin/env bash
# check-switch-fetches.py (plans/cmux-next/shared-projections.md): in the agent page's views, a
# listener that re-reads on a switch back (`visibilitychange`, `focus`) and an effect that reads
# data on every mount fail; listed listeners, marked mount reads, keyed reads and the real tree pass.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-switch-fetches.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-switch-fetches.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Runs the guard on a repo root whose only source is $2 at path $1.
check() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/$(dirname "$1")"
  printf '%s\n' "$2" > "$tmp/repo/$1"
  local code=0
  python3 -I "$CHECK" --root "$tmp/repo" >"$tmp/out" 2>&1 || code=$?
  # 0 = clean; 1 = a finding that names the file; anything else is a crash.
  if [[ $code -eq 1 ]] && ! grep -q "$1" "$tmp/out"; then code=3; fi
  return "$code"
}
ACPMUX=webviews/src/agent-session/acpmux
VIEW=$ACPMUX/newtab/Fixture.tsx
pass() { check "$1" "$3" || { echo "FAIL: must pass: $2" >&2; cat "$tmp/out" >&2; exit 1; }; }
fail() {
  local code=0
  check "$1" "$3" || code=$?
  [[ $code -eq 1 ]] || { echo "FAIL: must fail with a finding (got $code): $2" >&2; cat "$tmp/out" >&2; exit 1; }
}

fail "$VIEW" "a re-read on visibilitychange" 'document.addEventListener("visibilitychange", () => void callNative("chats.page"));'
fail "$VIEW" "a re-read on window focus" 'window.addEventListener("focus", reread);'
fail "$VIEW" "a re-read on pageshow" "window.addEventListener?.('pageshow', reread);"
fail "$VIEW" "a read on every mount" $'useEffect(() => {\n  void callNative("chats.page");\n}, []);'
fail "$VIEW" "a read whose only dependency is the read itself" $'useEffect(() => {\n  fetchPage("", undefined);\n}, [fetchPage]);'
fail "$ACPMUX/conversation/Fixture.tsx" "a layout effect read" $'useLayoutEffect(() => {\n  void loadRows();\n}, [loadRows]);'

pass "$ACPMUX/direct.ts" "a listed listener" 'document.addEventListener("visibilitychange", this.showChanged);'
pass "$VIEW" "a marked mount read" $'// mount-read: the spare\'s model is wired only now\nuseEffect(() => {\n  void callNative("project.list");\n}, []);'
pass "$VIEW" "a read keyed by its data" $'useEffect(() => {\n  void callNative("chat.read", { id });\n}, [id]);'
pass "$VIEW" "a read in a comment" $'useEffect(() => {\n  // callNative("x") was here\n}, []);'
pass "$VIEW" "an element's own focus listener" 'input.addEventListener("focus", onFocus);'
pass "$VIEW" "a read on each push" $'useEffect(() => subscribeDeviceChats(() => fetchPage("", undefined)), [fetchPage]);'
pass "$VIEW" "a state flag dependency" $'useEffect(() => {\n  if (!isLoading) void callNative("x");\n}, [isLoading]);'
pass "webviews/src/pages/Fixture.tsx" "a page outside the agent page" 'window.addEventListener("focus", reread);'

python3 -I "$CHECK" --self-test >/dev/null
# The real tree is clean.
python3 -I "$CHECK" >/dev/null
echo "check-switch-fetches: ok"
