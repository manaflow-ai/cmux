#!/usr/bin/env bash
# check-concentric-containers.py (Lawrence 2026-11-15: "all dialogs needs concentric padding with buttons
# inside"): a container that holds buttons with a corner of its own fails; one rounded from its buttons, a
# capsule, a reasoned exception and a baseline site pass; a fixed baseline site must leave the list.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-concentric-containers.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-concentric.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Runs the check on a repo root whose only source is $2 at path $1 (and baseline $3, if given).
check() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/$(dirname "$1")" "$tmp/repo/scripts/cmux-next"
  printf '%s\n' "$2" > "$tmp/repo/$1"
  printf '%s\n' "${3:-}" > "$tmp/repo/scripts/cmux-next/concentric-containers-baseline.txt"
  python3 -I "$CHECK" "$tmp/repo" >/dev/null 2>&1
}
SWIFT=Packages/macOS/CmuxNext/Sources/Fixture/FixtureCard.swift
CSS=webviews/src/fixture/styles.css
pass() { check "$1" "$3" "${4:-}" || { echo "FAIL: must pass: $2" >&2; exit 1; }; }
fail() { if check "$1" "$3" "${4:-}"; then echo "FAIL: must fail: $2" >&2; exit 1; fi; }

BUTTONS='let ok = CmuxDialogButtonView(button, hint: nil, target: self, action: #selector(go))'
fail "$SWIFT" "a panel's own corner around buttons" "$BUTTONS
let glass = Glass.makeOverlayPanel(content: body, cornerRadius: Metrics.surfaceCornerRadius)"
fail "$SWIFT" "the panel default corner around buttons" "$BUTTONS
let glass = Glass.makeOverlayPanel(content: body)"
fail "$SWIFT" "a literal surface corner around buttons" "$BUTTONS
        surface.cornerRadius = 14"
pass "$SWIFT" "the corner rounded from the buttons" "$BUTTONS
let glass = Glass.makeOverlayPanel(content: body, cornerRadius: Metrics.buttonContainer(padding: 16).outerRadius)"
pass "$SWIFT" "a token declared from the buttons" "$BUTTONS
static var cardCornerRadius: CGFloat { Metrics.buttonContainer(padding: padding).outerRadius }
        surface.cornerRadius = Self.cardCornerRadius"
pass "$SWIFT" "a capsule" "$BUTTONS
let glass = Glass.makeOverlayPanel(cornerRadius: Self.height / 2)"
pass "$SWIFT" "a reasoned exception" "$BUTTONS
let glass = Glass.makeOverlayPanel(content: body) // concentric-allow: the buttons sit 40 pt in, far from the corner"
pass "$SWIFT" "no buttons" "let glass = Glass.makeOverlayPanel(content: body, cornerRadius: 9)"

fail "$CSS" "a literal dialog corner" '.share-dialog { padding: 24px; border-radius: 14px; }'
fail "$CSS" "a hint with a token corner of its own" '.acpmux-cloud-hint { border-radius: var(--ds-radius-popup); }'
pass "$CSS" "a corner rounded from the buttons" '.ui-notice { --concentric-padding: 8px; border-radius: calc(var(--ds-radius-control) + var(--concentric-padding)); }'
pass "$CSS" "a capsule" '.find-strip { border-radius: 999px; }'
pass "$CSS" "an element of a card is not the card" '.pr-card__ref { border-radius: 3px; }'
pass "$CSS" "a reasoned exception" '.x-card { border-radius: 10px; /* concentric-allow: holds no buttons */ }'

# Keycap chips inside buttons (Lawrence 2026-11-15: the quit dialog's "esc" and "↩" chips were square-ish).
KEYCAP=Packages/macOS/CmuxNext/Sources/Fixture/FixtureKeycapView.swift
fail "$KEYCAP" "a keycap with a corner of its own" "        layer?.cornerRadius = 3"
pass "$KEYCAP" "a keycap rounded from its button" "        layer?.cornerRadius = CmuxDialogMetrics.keycap.childRadius(fitting: bounds.size)"
pass "$KEYCAP" "a keycap nested in its button" "        layer?.cornerRadius = Metrics.buttonCornerRadius(nestedIn: outer, inset: 5)"
fail "$CSS" "a literal keycap corner" '.acpmux-keycap { border-radius: 4px; }'
fail "$CSS" "a kbd in a button with a literal corner" '.x-action kbd { border-radius: 4px; }'
pass "$CSS" "a keycap concentric with its button" '.acpmux-keycap { border-radius: calc(var(--ds-radius-control, 8px) - var(--ds-space-1, 4px)); }'

# A card's close x in its corner (Lawrence 2026-11-15: the Updated card's x was not concentric with its corner).
CARD='let surface = CardSurfaceView(cornerRadius: Self.cardCornerRadius)'
fail "$SWIFT" "a card's x placed by hand" "$CARD
        closeButton.frame = NSRect(x: b.width - 4 - close, y: 4, width: close, height: close)"
pass "$SWIFT" "a card's x in its concentric corner" "$CARD
        closeButton.frame = Metrics.cornerControl(outerRadius: r, side: close).topTrailingFrame(side: close, in: b, flipped: true)"
pass "$SWIFT" "an x in a view with no card" "        closeButton.frame = NSRect(x: 0, y: 0, width: 16, height: 16)"
fail "$CSS" "a round close x in a card" '.wn-card-close { border-radius: 50%; }'
fail "$CSS" "a literal close x corner" '.x-card-close { border-radius: 9px; }'
pass "$CSS" "a close x concentric with its card" '.wn-card-close { --concentric-padding: 2px; border-radius: calc(var(--cmux-sidebar-card-radius) - var(--concentric-padding)); }'

LINE="$CSS: .share-dialog { border-radius: 14px }"
pass "$CSS" "a baseline site" '.share-dialog { border-radius: 14px; }' "$LINE"
fail "$CSS" "a fixed baseline site left in the list" '.share-dialog { border-radius: calc(var(--ds-radius-control) + 24px); }' "$LINE"
echo "check-concentric-containers tests: ok"
