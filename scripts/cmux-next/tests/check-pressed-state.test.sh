#!/usr/bin/env bash
# check-pressed-state.py (Lawrence 2026-11-15: "for all buttons, we should also not have boldness on active
# (mousedown) state ... we only want to have different bg color on mousedown"): a press that changes the
# weight, size, scale, offset, opacity or icon fails; a press that changes only the fill passes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-pressed-state.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-pressed-state.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

python3 -I "$CHECK" --self-test >/dev/null

# Runs the check on a repo root whose only source is $2 at path $1.
check() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/$(dirname "$1")"
  printf '%s\n' "$2" > "$tmp/repo/$1"
  python3 -I "$CHECK" "$tmp/repo" >/dev/null 2>&1
}
MAC=Packages/macOS/CmuxNext/Sources/Fixture/FixtureButton.swift
IOS=cmux-next-ios/CmuxMobileKit/Sources/Fixture/FixtureButton.swift
CSS=webviews/src/fixture/styles.css
TSX=webviews/src/fixture/Bar.tsx
GALLERY=webviews/src/gallery/fixture/styles.css
TEST=Packages/macOS/CmuxNext/Tests/FixtureTests/FixtureTests.swift
pass() { check "$1" "$3" || { echo "FAIL: must pass: $2" >&2; exit 1; }; }
fail() { if check "$1" "$3"; then echo "FAIL: must fail: $2" >&2; exit 1; fi; }

fail "$CSS" "bold on :active" '.b:active { font-weight: 600; }'
fail "$CSS" "a press scale" '.b:active { background: x; transform: scale(0.97); }'
fail "$CSS" "a nested press padding" '.b { &:active { padding: 2px; } }'
fail "$CSS" "a press ink the hover lacks" '.b:active { color: red; }'
fail "$CSS" "a held-frame font size" '.b[data-press-active] { font-size: 13px; }'
fail "$CSS" "an on toggle that turns bold" '.seg .ui-btn[data-pressed] { font-weight: var(--weight-emphasis); }'
fail "$CSS" "hover and press both bold" '.b:hover, .b:active { font-weight: 600; }'
fail "$TSX" "a Tailwind press scale" 'const c = "px-2 active:scale-95";'
fail "$TSX" "a Tailwind press weight" 'const c = `active:font-semibold`;'
fail "$MAC" "a SwiftUI press scale" '        label.scaleEffect(configuration.isPressed ? 0.98 : 1)'
fail "$MAC" "a SwiftUI press weight" '        label.fontWeight(configuration.isPressed ? .semibold : .regular)'
fail "$MAC" "an AppKit bold press" $'        if isPressed {\n            title.font = .boldSystemFont(ofSize: 12)\n        }'
fail "$MAC" "an AppKit press shrink" '        layer.transform = pressed ? shrink : CATransform3DIdentity'
fail "$MAC" "SwiftUI plain dims the label" '        .buttonStyle(.plain)'
fail "$IOS" "a dimmed label" '            .opacity(configuration.isPressed ? 0.85 : 1)'
fail "$IOS" "SwiftUI borderless dims the label" '        .buttonStyle(.borderless)'
pass "$CSS" "a press fill" '.b:active:not(:disabled) { background: var(--ds-color-pressed); cursor: default; }'
pass "$CSS" "a press that shares the hover look" '.b:is(:hover, :active) { color: x; box-shadow: inset 0 0 0 1px y; }'
pass "$CSS" "a press that takes a ring away" '.b:is(:active, [aria-expanded=true]) { background: x; box-shadow: none; }'
pass "$CSS" "an on toggle with a selected fill" '.b[aria-pressed="true"] { background: x; color: y; }'
pass "$CSS" "a :not(:active) rule" '.b:not(:hover, :active) { font-weight: 600; }'
pass "$CSS" "a reasoned exception" '.b:active { transform: translateY(1px); } /* pressed-state: allow a drag handle that follows the pointer */'
pass "$GALLERY" "a gallery fixture" '.b:active { font-weight: 600; }'
pass "$TSX" "a Tailwind press fill" 'const c = "active:bg-pressed"; const o = { active: true };'
pass "$MAC" "the shared style" '        .buttonStyle(.cmuxPressFill)'
pass "$MAC" "a press fill" '        let fill = isPressed ? Palette.pressedFill : nil'
pass "$IOS" "a press wash" $'            .background {\n                theme.colors.fillSelected.color\n                    .opacity(configuration.isPressed ? 1 : 0)'
pass "$TEST" "a test" '        .buttonStyle(.plain)'

echo "check-pressed-state tests: ok"
