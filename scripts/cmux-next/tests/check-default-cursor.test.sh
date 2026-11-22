#!/usr/bin/env bash
# check-default-cursor.py (DEFAULT-CURSOR): a new pointing hand in cmux-next UI fails (Swift
# `pointingHand` / `pointerStyle(.link)`, webview `cursor: pointer` / `cursor-pointer`), an
# allowlisted file passes, a comment does not count, and a stale allowlist entry fails.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-default-cursor.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-default-cursor.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Runs the guard on a repo root whose only source is $2 at path $1 and whose allowlist is $3.
check() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/$(dirname "$1")" "$tmp/repo/scripts/cmux-next"
  printf '%s\n' "$2" > "$tmp/repo/$1"
  printf '%b' "${3:-}" > "$tmp/repo/scripts/cmux-next/pointer-cursor-allowlist.txt"
  local code=0
  python3 -I "$CHECK" "$tmp/repo" >/dev/null 2>"$tmp/err" || code=$?
  echo "$code"
}

expect() {
  local want="$1" name="$2" got
  got="$(check "$3" "$4" "${5:-}")"
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: $name (exit $got, want $want)" >&2
    cat "$tmp/err" >&2
    exit 1
  fi
}

S=Packages/macOS/CmuxNext/Sources/X/Button.swift
W=webviews/src/pages/x/styles.css
T=webviews/src/pages/x/View.tsx

expect 1 "swift addCursorRect pointingHand" "$S" '    addCursorRect(bounds, cursor: .pointingHand)'
expect 1 "swift NSCursor.pointingHand.set" "$S" '    NSCursor.pointingHand.set()'
expect 1 "swift pointerStyle(.link)" "$S" '    content.pointerStyle(.link)'
expect 1 "shared package swift" Packages/Shared/Lab/Sources/A.swift 'NSCursor.pointingHand.push()'
expect 0 "swift test target" Packages/macOS/CmuxNext/Tests/XTests/A.swift '#expect(c !== NSCursor.pointingHand)'
expect 0 "swift arrow" "$S" '    NSCursor.arrow.set()'
expect 0 "swift comment" "$S" '/// No pointingHand here (the arrow, as native apps do).'
expect 0 "swift allowlisted" "$S" 'view.setCursor(.pointingHand)' "$S # terminal URL\n"
expect 1 "css pointer" "$W" '.x { cursor: pointer; }'
expect 1 "minified css pointer" "$W" '.x{border:0;cursor:pointer}'
expect 1 "tailwind cursor-pointer" "$T" '<button className="flex cursor-pointer" />'
expect 1 "tailwind variant" "$T" '<button className="hover:cursor-pointer" />'
expect 1 "inline style" "$T" '<div style={{ cursor: "pointer" }} />'
expect 0 "css default" "$W" '.x { cursor: default; }'
expect 0 "css comment" "$W" '/* was cursor: pointer */ .x { cursor: default; }'
expect 0 "css resize" "$W" '.x { cursor: col-resize; }'
expect 0 "webview test file" webviews/src/pages/x/a.test.ts 'const c = "cursor: pointer";'
expect 1 "stale allowlist entry" "$S" '    NSCursor.arrow.set()' "$S # gone\n"

echo "check-default-cursor: ok"
