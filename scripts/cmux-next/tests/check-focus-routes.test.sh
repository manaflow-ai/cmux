#!/usr/bin/env bash
# check-focus-routes.py (plans/cmux-next/focus-loss-AUDIT.md, "Focus route"): a direct keyboard
# move in product Swift (makeFirstResponder, makeKey, makeKeyAndOrderFront, NSApp.activate) or page
# code (.focus(), .blur(), autoFocus) fails; the route, a `focus-route:` reason, overrides, super
# calls, comments, strings and tests pass; the baseline counts per file and only goes down.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-focus-routes.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-focus-routes.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

check() {
  local baseline="$1"
  shift
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/scripts/cmux-next"
  printf '%b' "$baseline" > "$tmp/repo/scripts/cmux-next/focus-routes-baseline.tsv"
  local pair
  for pair in "$@"; do
    mkdir -p "$tmp/repo/$(dirname "${pair%%=*}")"
    printf '%s\n' "${pair#*=}" > "$tmp/repo/${pair%%=*}"
  done
  local code=0
  python3 -I "$CHECK" "$tmp/repo" >/dev/null 2>"$tmp/err" || code=$?
  return "$code"
}
SW=Packages/macOS/CmuxNext/Sources/CmuxNextKit/A.swift
TS=webviews/src/pages/a/A.tsx
pass() {
  local what="$1"
  shift
  check "$@" || { echo "FAIL: must pass: $what" >&2; cat "$tmp/err" >&2; exit 1; }
}
fail() {
  local what="$1"
  shift
  local code=0
  check "$@" || code=$?
  [[ $code -eq 1 ]] || { echo "FAIL: must fail with a finding (got $code): $what" >&2; cat "$tmp/err" >&2; exit 1; }
}

fail "window makeFirstResponder" "" "$SW=        window?.makeFirstResponder(field)"
fail "a bare makeFirstResponder" "" "$SW=        makeFirstResponder(webView)"
fail "makeKey" "" "$SW=        panel.makeKey()"
fail "makeKeyAndOrderFront" "" "$SW=        window.makeKeyAndOrderFront(nil)"
fail "NSApp.activate" "" "$SW=        NSApp.activate()"
fail "an element focus" "" "$TS=  input.current?.focus();"
fail "an element blur" "" "$TS=  document.activeElement?.blur();"
fail "an autoFocus prop" "" "$TS=  return <input autoFocus />;"
fail "one more than the baseline" "$SW\t1\n" "$SW=        a.makeFirstResponder(b)
        c.makeFirstResponder(d)"

pass "the route" "" "$SW=        FocusRoute(.system, \"why\").moveKeyboard(in: window, to: field)"
pass "the web route" "" "$TS=  focusRoute(input.current, \"system\", \"why\");"
pass "a reason on the line above" "" "$SW=        // focus-route: the override's own super call
        window.makeFirstResponder(nil)"
pass "an override and super" "" "$SW=    override func makeFirstResponder(_ r: NSResponder?) -> Bool { super.makeFirstResponder(r) }"
pass "a declaration" "" "$SW=    func makeFirstResponder(_ r: NSResponder?, through route: FocusRoute) -> Bool"
pass "a comment" "" "$SW=        // window.makeFirstResponder(field) was the old way"
pass "a JS string in Swift" "" "$SW=        let script = \"document.querySelector('input').focus()\""
pass "autoFocus false" "" "$TS=  return <input autoFocus={false} />;"
pass "a test file" "" "webviews/src/pages/a/A.test.ts=  input.focus();"
pass "a playground" "" "Packages/macOS/CmuxNext/Sources/CmuxNextKit/ThemePlayground.swift=        window.makeKey()"
pass "the baseline count" "$SW\t2\n" "$SW=        a.makeFirstResponder(b)
        c.makeFirstResponder(d)"
pass "fewer than the baseline is a note" "$SW\t3\n" "$SW=        a.makeFirstResponder(b)"
pass "the route files" "" "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/FocusRoute/FocusRoute.swift=        window.makeFirstResponder(r)" "webviews/src/ui/focusRoute.ts=  element.focus();"
echo "check-focus-routes: ok"
