#!/usr/bin/env bash
# check-button-radius.py (Lawrence 2026-11-12: "roundness of all buttons should match roundness of
# tabs/workspaces"): a button's corner off the one tab token fails; the token, its nested form and a
# reasoned exception pass.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-button-radius.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-button-radius.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Runs the check on a repo root whose only source is $2 at path $1.
check() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/$(dirname "$1")"
  printf '%s\n' "$2" > "$tmp/repo/$1"
  python3 -I "$CHECK" "$tmp/repo" >/dev/null 2>&1
}
BUTTON=Packages/macOS/CmuxNext/Sources/Fixture/FixtureButton.swift
OTHER=Packages/macOS/CmuxNext/Sources/Fixture/Fixture.swift
CSS=webviews/src/fixture/styles.css
TSX=webviews/src/fixture/Bar.tsx
GALLERY=webviews/src/gallery/fixture/styles.css
pass() { check "$1" "$3" || { echo "FAIL: must pass: $2" >&2; exit 1; }; }
fail() { if check "$1" "$3"; then echo "FAIL: must fail: $2" >&2; exit 1; fi; }

fail "$BUTTON" "a literal button corner" '        layer?.cornerRadius = 6'
fail "$BUTTON" "a capsule button" '        layer?.cornerRadius = bounds.height / 2'
fail "$BUTTON" "the item corner on a button" '        layer?.cornerRadius = Metrics.itemCornerRadius'
fail "$BUTTON" "the control corner in a SwiftUI shape" '        .background(fill, in: RoundedRectangle(cornerRadius: Metrics.controlCornerRadius))'
fail "$BUTTON" "a drawn rounded rect" '        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()'
fail "$OTHER" "a button token declared with a literal" '    static var buttonCornerRadius: CGFloat { 7 }'
fail "$OTHER" "a button rounded from another file" '        button.layer?.cornerRadius = Metrics.surfaceCornerRadius'
pass "$BUTTON" "the one token" '        layer?.cornerRadius = Metrics.buttonCornerRadius'
pass "$BUTTON" "the token fitted to the button" '        layer?.cornerRadius = Metrics.buttonCornerRadius(fitting: bounds.size)'
pass "$BUTTON" "the token nested in a card" '        layer?.cornerRadius = Metrics.buttonCornerRadius(nestedIn: card, inset: 4)'
pass "$BUTTON" "a radius passed along" '        layer?.cornerRadius = cornerRadius'
pass "$BUTTON" "a square corner" '        layer?.cornerRadius = 0'
pass "$BUTTON" "a reasoned exception" '        track.cornerRadius = size.height / 2 // radius-allow: a switch track, not a button face'
pass "$OTHER" "a card that is not a button" '        layer?.cornerRadius = Metrics.panelCornerRadius'
pass "$OTHER" "a button token reading the tab token" '    static var buttonCornerRadius: CGFloat { Metrics.tabCornerRadius }'
pass "$BUTTON" "a radius in a comment" '        // layer?.cornerRadius = 6 was the old corner'

fail "$CSS" "a literal button corner" '.save-button { border-radius: 6px; }'
fail "$CSS" "a pill button" 'button.pill { border-radius: 999px; }'
fail "$CSS" "another radius token on a button" '.ui-btn[data-size="sm"] { border-radius: var(--ds-radius-sm); }'
fail "$CSS" "a nested button rule" '.bar { .bar-button { border-radius: 4px; } }'
fail "$CSS" "a role=button" '[role="button"] { border-radius: 5px; }'
pass "$CSS" "the control token" '.save-button { border-radius: var(--ds-radius-control); }'
pass "$CSS" "the control token nested" '.seg .seg-button { border-radius: calc(var(--ds-radius-control) - 2px); }'
pass "$CSS" "the host token" '.save-button { border-radius: var(--cmux-button-radius); }'
pass "$CSS" "a square button" '.save-button { border-radius: 0; }'
pass "$CSS" "an icon inside a button" '.save-button svg { border-radius: 2px; }'
pass "$CSS" "a card" '.card { border-radius: 12px; }'
pass "$CSS" "a reasoned exception" '.switch-button { border-radius: 999px; /* radius-allow: a switch track */ }'
pass "$CSS" "a commented-out radius" '.save-button { /* border-radius: 6px; */ }'
pass "$GALLERY" "a gallery compares looks" '.variant-button { border-radius: 12px; }'

fail "$TSX" "a Tailwind radius on a button" '<button className="h-6 rounded-md px-2">Save</button>'
fail "$TSX" "a capsule button" '<button className="rounded-full">Save</button>'
pass "$TSX" "the control radius" '<button className="h-6 rounded-control px-2">Save</button>'
pass "$TSX" "a div with a radius" '<div className="rounded-md">card</div>'

echo "check-button-radius tests: ok"
