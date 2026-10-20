#!/usr/bin/env bash
# check-single-omnibar.py (ONE-OMNIBAR): a second address bar type or the
# omnibar's URL styling outside the omnibar fails; the omnibar's own types
# and a view that shows AddressBarView pass.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-single-omnibar.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-single-omnibar.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Runs the guard on a repo root (not a git checkout) whose only source is $2 at path $1.
check() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/$(dirname "$1")"
  printf '%s\n' "$2" > "$tmp/repo/$1"
  local code=0
  python3 -I "$CHECK" "$tmp/repo" >/dev/null 2>"$tmp/err" || code=$?
  # 0 = clean; 1 = a finding that names the file; anything else is a crash.
  if [[ $code -eq 1 ]] && ! grep -q "$1" "$tmp/err"; then code=3; fi
  return "$code"
}
SRC=Packages/macOS/CmuxNext/Sources
pass() { check "$1" "$3" || { echo "FAIL: must pass: $2" >&2; cat "$tmp/err" >&2; exit 1; }; }
fail() {
  local code=0
  check "$1" "$3" || code=$?
  [[ $code -eq 1 ]] || { echo "FAIL: must fail with a finding (got $code): $2" >&2; cat "$tmp/err" >&2; exit 1; }
}

fail "$SRC/CmuxNextBrowser/UI/PopupLocationBarView.swift" "a popup location bar" 'public final class PopupLocationBarView: NSView {}'
fail "$SRC/CmuxNextPopups/X.swift" "a second address field" 'final class PopupAddressField: NSTextField {}'
fail "$SRC/CmuxNextApp/X.swift" "a URL bar struct" 'struct MiniURLBar: View {}'
fail "$SRC/CmuxNextApp/X.swift" "an omnibar-like view" '@MainActor final class CompactOmnibarView: NSView {}'
fail "$SRC/CmuxNextPopups/X.swift" "host styling outside the omnibar" \
  'let host = BrowserURLDisplay.hostRange(in: text, for: url)'

pass "$SRC/CmuxNextBrowser/UI/AddressBarView.swift" "the omnibar itself" 'public final class AddressBarView: NSView {}'
pass "$SRC/CmuxNextBrowser/UI/AddressField.swift" "the omnibar's field styles the host" \
  $'final class AddressField: ChromeTextField {}\nlet host = BrowserURLDisplay.hostRange(in: text, for: url)'
pass "$SRC/CmuxNextPopups/BrowserPopupWindow.swift" "a window that shows the omnibar" \
  $'public final class BrowserPopupWindow: NSWindow {\n  let locationBar = OmnibarToolbarView(suggestionEngine: e)\n  let t = BrowserURLDisplay.displayText(for: url)\n}'
pass "$SRC/CmuxNextApp/X.swift" "an unrelated name" 'final class AddressBookImporter {}'

# The real tree is clean.
python3 -I "$CHECK" "$ROOT_DIR" >/dev/null
echo "check-single-omnibar tests: ok"
