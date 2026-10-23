#!/usr/bin/env bash
# check-overlay-glass.py: a floating surface painted solid (the popup surface, an elevated fill, a
# system window color, ReduceTransparency.alwaysOpaque, the opt-in card fill, a solid SwiftUI
# background, AppKit's tooltip material, a tooltip or hover window without the shared glass) fails; a `glass-opaque-allow:` reason and the shared glass pass; a stale allowance fails.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-overlay-glass.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-overlay-glass.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
src="$tmp/Packages/macOS/CmuxNext/Sources/CmuxNextDemo"
mkdir -p "$src"

expect_fail() {
  local name="$1" rule="$2" body="$3"
  rm -f "$src"/*.swift
  printf '%s\n' "$body" > "$src/$name.swift"
  if out="$(python3 -I "$CHECK" "$tmp")"; then
    echo "check-overlay-glass.test: $name passed, expected [$rule]"; echo "$out"; exit 1
  fi
  grep -q "\[$rule\]" <<<"$out" || { echo "check-overlay-glass.test: $name did not name [$rule]"; echo "$out"; exit 1; }
}

expect_pass() {
  local name="$1" body="$2"
  rm -f "$src"/*.swift
  printf '%s\n' "$body" > "$src/$name.swift"
  out="$(python3 -I "$CHECK" "$tmp")" || { echo "check-overlay-glass.test: $name failed"; echo "$out"; exit 1; }
}

expect_fail popup popup-surface '        layer?.backgroundColor = performWithTheme { Palette.popupSurface.cgColor }'
expect_fail elevated elevated-fill '            background.layer?.backgroundColor = Palette.elevatedBackground.cgColor'
expect_fail system system-solid '        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor'
expect_fail opaque always-opaque '        let surface = CardSurfaceView(cornerRadius: 6, reduceTransparency: .alwaysOpaque)'
expect_fail card card-fill '        let panel = Glass.makeOverlayPanel(content: body, cardFill: true)'
expect_fail swiftui swiftui-solid '            .background(Color(nsColor: Palette.popupSurface))'
expect_fail tipmaterial tooltip-material '        blur.material = .toolTip'
expect_fail tipwindow hover-window 'final class TooltipPanel: NSPanel {
    let blur = NSVisualEffectView()
}'
expect_fail previewwindow hover-window 'final class LinkHoverPreviewWindow: NSWindow {}'

expect_pass glass '        let panel = Glass.makeOverlayPanel(content: body, cornerRadius: 10)'
expect_pass glasswindow 'final class TooltipPanel: NSPanel {
    let glass = Glass.makeOverlayPanel(cornerRadius: 5, interactive: false)
}'
expect_pass otherwindow 'final class TabDragGhostPanel: NSPanel {}'
expect_pass translucent '        box.fillColor = NSColor.textBackgroundColor.withAlphaComponent(0.35)'
expect_pass comment '/// The popup surface (`Palette.popupSurface`) only under Reduce Transparency.'
expect_pass escaped '        // glass-opaque-allow: Reduce Transparency draws every surface solid.
        layer?.backgroundColor = (opaque ? Palette.elevatedBackground : veil).cgColor'

# Hover card bodies (a file with HoverCardBody or HoverCardTextReporting) draw on the one glass
# hover card window: no window or material of their own, and no fill a solid card could hide in.
expect_fail hover-window hover-own-window 'final class DemoCardView: NSView, HoverCardTextReporting {
    let popover = NSPopover()
}'
expect_fail hover-surface hover-own-window '        let body = HoverCardBody(view: Glass.makeOverlayPanel(content: card), placement: .beside, themeAnchor: self) {}'
expect_fail hover-fill hover-body-fill 'final class DemoCardView: NSView, HoverCardTextReporting {
    func applyColors() { layer?.backgroundColor = Palette.background.cgColor }
}'
expect_fail hover-ternary hover-body-fill 'final class DemoCardView: NSView, HoverCardTextReporting {
    func applyColors() { layer?.backgroundColor = hovered ? Palette.hoverFill.cgColor : Palette.textPrimary.cgColor }
}'
expect_pass hover-glass 'final class DemoCardView: NSView, HoverCardTextReporting {
    func applyColors() {
        thumbnail.layer?.backgroundColor = Palette.hoverFill.cgColor
        layer?.backgroundColor = hovered ? Palette.hoverFill.cgColor : NSColor.clear.cgColor
        pill.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
    }
}'
expect_pass hover-escaped 'final class DemoCardView: NSView, HoverCardTextReporting {
    // glass-opaque-allow: a status dot, not a card fill.
    func applyColors() { dot.layer?.backgroundColor = tone.cgColor }
}'
# Only hover card bodies: the same fill elsewhere is not this rule'"'"'s business.
expect_pass not-hover '        badge.layer?.backgroundColor = Palette.accent.cgColor'

# A listed file that no longer paints the solid fill is a stale allowance.
stale="$tmp/Packages/macOS/CmuxNext/Sources/CmuxNextTerminal"
mkdir -p "$stale"
rm -f "$src"/*.swift
printf '%s\n' '        layer?.backgroundColor = Palette.hoverFill.cgColor' > "$stale/TerminalStatusBanner.swift"
if out="$(python3 -I "$CHECK" "$tmp")"; then
  echo "check-overlay-glass.test: a stale allowance passed"; echo "$out"; exit 1
fi
grep -q "stale allowance" <<<"$out" || { echo "check-overlay-glass.test: no stale allowance named"; echo "$out"; exit 1; }

echo "check-overlay-glass.test: ok"
