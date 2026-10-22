#!/usr/bin/env bash
# check-no-swiftui.py (NO-SWIFTUI): a macOS file that imports SwiftUI outside
# the allowlist fails, a stale allowlist entry fails, an AppKit file passes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-no-swiftui.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-no-swiftui.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
LIST=scripts/cmux-next/no-swiftui-allowlist.txt
SRC=Packages/macOS/CmuxNext/Sources

# check PATH SOURCE ALLOWLIST: runs the guard on a repo root (not a git
# checkout) whose only source is SOURCE at PATH.
check() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/$(dirname "$1")" "$tmp/repo/$(dirname "$LIST")"
  printf '%s\n' "$2" > "$tmp/repo/$1"
  printf '%s' "$3" > "$tmp/repo/$LIST"
  local code=0
  python3 -I "$CHECK" "$tmp/repo" >/dev/null 2>"$tmp/err" || code=$?
  return "$code"
}
pass() { check "$1" "$3" "${4:-}" || { echo "FAIL: must pass: $2" >&2; cat "$tmp/err" >&2; exit 1; }; }
fail() {
  local code=0
  check "$1" "$3" "${4:-}" || code=$?
  [[ $code -eq 1 ]] || { echo "FAIL: must fail with a finding (got $code): $2" >&2; cat "$tmp/err" >&2; exit 1; }
}

fail "$SRC/CmuxNextApp/X.swift" "a plain import" $'import AppKit\nimport SwiftUI'
fail "$SRC/CmuxNextApp/X.swift" "a public import" 'public import SwiftUI'
fail "$SRC/CmuxNextApp/X.swift" "a preconcurrency import" '@preconcurrency import SwiftUI'
fail "$SRC/CmuxNextApp/X.swift" "a scoped import" 'import struct SwiftUI.Color'
fail "$SRC/CmuxNextApp/X.swift" "a stale allowlist entry" 'import AppKit' "$SRC/CmuxNextApp/X.swift"
fail "$SRC/CmuxNextApp/X.swift" "an entry for a missing file" 'import AppKit' "$SRC/CmuxNextApp/Gone.swift"
fail "Packages/macOS/CmuxNext/Tests/T/XTests.swift" "a test file" 'import SwiftUI'

pass "$SRC/CmuxNextApp/X.swift" "AppKit only" $'import AppKit\nimport QuartzCore'
pass "$SRC/CmuxNextApp/X.swift" "an allowlisted file" 'import SwiftUI' "$SRC/CmuxNextApp/X.swift"
pass "$SRC/CmuxNextApp/X.swift" "an import in a comment" $'import AppKit\n// import SwiftUI\n/* import SwiftUI */'
pass "$SRC/CmuxNextApp/X.swift" "a SwiftUIish module name" 'import SwiftUIIntrospect'
pass "Packages/iOS/X.swift" "iOS is out of scope" 'import SwiftUI'
echo "check-no-swiftui: ok"
