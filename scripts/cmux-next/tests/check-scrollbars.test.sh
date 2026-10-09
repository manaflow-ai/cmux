#!/usr/bin/env bash
# check-scrollbars.sh (SCROLLBARS-FOLLOW-MACOS): forced scroller styles, hidden
# indicators and custom web scrollbars fail the gate; following the system and
# CSS comments pass.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-scrollbars.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-scrollbars.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Runs the gate on a repo root whose only source is $2 at path $1.
check() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/$(dirname "$1")"
  printf '%s\n' "$2" > "$tmp/repo/$1"
  bash "$CHECK" "$tmp/repo" >/dev/null 2>&1
}
SWIFT=Packages/macOS/CmuxNext/Sources/Fixture/Fixture.swift
CSS=webviews/src/fixture/styles.css
TSX=webviews/src/fixture/List.tsx
PIERRE=webviews/src/agent-session/acpmux/conversation/EditDiff.tsx
pass() { check "$1" "$3" || { echo "FAIL: must pass: $2" >&2; exit 1; }; }
fail() { if check "$1" "$3"; then echo "FAIL: must fail: $2" >&2; exit 1; fi; }

fail "$SWIFT" "a forced legacy style" '        scroll.scrollerStyle = .legacy'
fail "$SWIFT" "a forced overlay style" '        scrollerStyle = .overlay'
fail "$SWIFT" "hidden SwiftUI indicators" '        ScrollView(.horizontal, showsIndicators: false) {'
fail "$SWIFT" "never-shown indicators" '        .scrollIndicators(.never)'
fail "$SWIFT" "always-visible indicators" '        .scrollIndicators(.visible)'
fail "$SWIFT" "an empty scroller track" '        scroll.autohidesScrollers = false'
pass "$SWIFT" "autohiding scrollers" '        scroll.autohidesScrollers = true'
pass "$SWIFT" "following the system" '        SystemScrollers.follow(scroll)'
pass "$SWIFT" "a comment" '        // never set scrollerStyle = .legacy here'
fail "$CSS" "overflow: scroll" '.list { overflow-y: scroll; }'
fail "$CSS" "a custom WebKit scrollbar" '.list::-webkit-scrollbar { width: 6px; }'
fail "$CSS" "scrollbar-width" '.list { scrollbar-width: thin; }'
fail "$CSS" "scrollbar-color" '.list { scrollbar-color: red transparent; }'
fail "$CSS" "scrollbar-gutter: stable" '.list { scrollbar-gutter: stable; }'
fail "$TSX" "a Tailwind overflow-y-scroll class" '<div className="min-h-0 overflow-y-scroll p-1" />'
fail "$TSX" "a Tailwind overflow-scroll class" '<div className="overflow-scroll" />'
fail "$TSX" "a React overflowY scroll style" '<div style={{ overflowY: "scroll" }} />'
fail "$TSX" "a React scrollbarWidth style" '<div style={{ scrollbarWidth: "none" }} />'
fail "$TSX" "a Tailwind arbitrary scrollbar-width" '<div className="[scrollbar-width:none]" />'
pass "$TSX" "a Tailwind overflow-y-auto class" '<div className="min-h-0 overflow-y-auto p-1" />'
pass "$PIERRE" "the @pierre/diffs overflow option" '    overflow: "scroll" as const,'
fail "$PIERRE" "a custom scrollbar in an allowed-rule file" '.x::-webkit-scrollbar { width: 0 }'
pass "$CSS" "overflow: auto" '.list { overflow: auto; }'
pass "$CSS" "a CSS comment" '/* no scrollbar-width: here */ .list { overflow: auto; }'
echo "check-scrollbars tests: ok"
