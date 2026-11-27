#!/usr/bin/env bash
# check-dialog-key-hints.py (u2647): a dialog button made around the shared key-hint components
# fails; the shared components, exempt lines and non-dialog web buttons pass.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-dialog-key-hints.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-dialog-key-hints.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Runs the guard on a repo root whose only source is $2 at path $1.
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
SW=Packages/macOS/CmuxNext/Sources/CmuxNextFixture/Fixture.swift
OWNER=Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Dialog/Fixture.swift
WEB=webviews/src/pages/fixture/Fixture.tsx
pass() { check "$1" "$3" || { echo "FAIL: must pass: $2" >&2; cat "$tmp/err" >&2; exit 1; }; }
fail() {
  local code=0
  check "$1" "$3" || code=$?
  [[ $code -eq 1 ]] || { echo "FAIL: must fail with a finding (got $code): $2" >&2; cat "$tmp/err" >&2; exit 1; }
}

fail "$SW" "a SwiftUI default button" '        Button(title) { save() }.keyboardShortcut(.defaultAction)'
fail "$SW" "a SwiftUI cancel button" '            .keyboardShortcut( .cancelAction)'
fail "$SW" "an NSButton bound to Return by hand" '        done.keyEquivalent = "\r"'
fail "$SW" "an NSButton bound to Escape by hand" '        deny.keyEquivalent = "\u{1b}"'
fail "$SW" "a SwiftUI system alert" '        .alert(title, isPresented: $shown) {'
fail "$SW" "a SwiftUI confirmation dialog" '        .confirmationDialog(title, isPresented: $asking) {'
fail "$SW" "an NSAlert" '        let alert = NSAlert()'
fail "$WEB" "a raw button in a FormDialog" $'<FormDialog actions={<button type="button" className="hc-text-button">Cancel</button>} />'
fail "$WEB" "a raw button whose class is on a later line" $'<Sheet>\n  <button\n    type="button"\n    className="cloud-button primary"\n  >Create</button>\n</Sheet>'

pass "$SW" "the shared SwiftUI button" '        CmuxDialogActionButton(title, hint: .return) { save() }'
pass "$SW" "the shared AppKit key" '        done.keyHint = .return'
pass "$SW" "an enum case named alert" '        case .alert(let message):'
pass "$SW" "a comment" '        // never .keyboardShortcut(.defaultAction) here'
pass "$SW" "an exempt line" $'        // dialog-keys-exempt: the page keeps Return\n        field.keyEquivalent = "\\r"'
pass "$OWNER" "the shared component binds the keys itself" '        keyEquivalent = "\r"'
pass "$WEB" "the shared web button" $'<FormDialog actions={<DialogButton dialogKey="escape" className="hc-text-button">Cancel</DialogButton>} />'
pass "$WEB" "a page button outside any dialog" '<button type="button" className="hc-text-button">Reply</button>'
pass "$WEB" "an icon button in a dialog" $'<Dialog>\n  <button type="button" className="acpmux-image-viewer-action" aria-label="Close" />\n</Dialog>'

# The real tree is clean.
python3 -I "$CHECK" "$ROOT_DIR" >/dev/null
echo "check-dialog-key-hints: ok"
