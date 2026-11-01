#!/usr/bin/env bash
# check-overlay-glass.py: a floating surface painted solid (the popup surface, an elevated fill, a
# system window color, ReduceTransparency.alwaysOpaque, the opt-in card fill, a solid SwiftUI
# background, AppKit's tooltip material, a tooltip or hover window without the shared glass, a toast, sheet or card window without it, a
# near-opaque veil on a glass surface, the card fill outside its file) fails; a `glass-opaque-allow:` reason and the shared glass pass; a stale allowance fails.
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
# A SurfaceRole's glass (Glass.makeSurface) is the shared glass too.
expect_pass tipwindow-role 'final class TooltipPanel: NSPanel {
    let glass = Glass.makeSurface(.tooltip, cornerRadius: 5, interactive: false)
}'
expect_pass menu-panel-role 'final class DemoMenuPanel: NSPanel {
    let card = Glass.makeSurface(.menu, content: rows)
}'

# Toasts, sheets, dialogs, cards, banners, bubbles and notices are glass too: their window builds the
# shared glass, no near-opaque veil lies over it, and the mostly opaque card fill stays in its file.
expect_fail toast-window surface-window 'final class DemoToastPanel: NSPanel {
    let blur = NSView()
}'
expect_fail sheet-window surface-window 'final class DemoSheetWindow: NSWindow {}'
expect_pass toast-window-glass 'final class DemoToastPanel: NSPanel {
    let surface = Glass.makeOverlayPanel(content: body, tone: .neutralGlass(.toast))
}'
expect_pass sheet-window-surface-role 'final class DemoSheetPanel: NSPanel {
    let surface = Glass.makeSurface(.sheet, content: body)
}'
expect_fail dense-veil-surface-role dense-fill 'final class DemoCard: NSView {
    let surface = Glass.makeSurface(.card, content: body)
    func paint() { veil.layer?.backgroundColor = Palette.textPrimary.withAlphaComponent(0.95).cgColor }
}'
expect_pass card-window-raw-glass 'final class DemoCardPanel: NSPanel {
    let glass = Glass.makePanel(content: body, style: .regular, cornerRadius: 14)
}'
expect_pass card-window-overlay-surface 'final class DemoCardPanel: NSPanel {
    let backdrop = OverlaySurfaceView(material: nil)
}'
expect_pass toast-window-escaped '// glass-opaque-allow: a test window that never shows
final class DemoToastPanel: NSPanel {}'
expect_fail dense-veil dense-fill 'final class DemoCard: NSView {
    let surface = Glass.makeOverlayPanel(content: body)
    func paint() { veil.layer?.backgroundColor = Palette.textPrimary.withAlphaComponent(0.94).cgColor }
}'
expect_fail dense-swiftui dense-fill 'struct DemoCard: View {
    let surface = CardSurfaceView()
    var body: some View { Text("x").background(Color.gray.opacity(0.95)) }
}'
expect_pass light-veil 'final class DemoCard: NSView {
    let surface = Glass.makeOverlayPanel(content: body)
    func paint() { veil.layer?.backgroundColor = Palette.textPrimary.withAlphaComponent(0.13).cgColor }
}'
# A pane that builds no glass is not a floating surface: its dense fill is not this rule's.
expect_pass dense-no-glass '        pane.layer?.backgroundColor = Palette.textPrimary.withAlphaComponent(0.94).cgColor'
expect_fail card-material card-material '        let card = CardMaterial(tokens, lift: 0.1)'

expect_fail menu-panel popup-host 'final class DemoMenuPanel: NSPanel {
    let card = NSVisualEffectView()
}'
expect_fail picker-host popup-host '        popup.panel.adoptPopupStyle(card: plainView)'
expect_fail native-host popup-host '    private let popup = NativePopupHost(panel: NativePopupPanel(identifier: "cmux.demo"))'
expect_fail ns-popover popup-host '        let pop = NSPopover()'
# Glass elsewhere in the file is not the host's: the panel class itself must build it.
expect_fail menu-panel-other-glass popup-host 'final class BadMenuPanel: NSPanel { let card = NSVisualEffectView() }
let other = Glass.makeOverlayPanel(content: otherView)'
expect_fail menu-panel-sibling-glass popup-host 'final class BadMenuPanel: NSPanel {
    let card = NSVisualEffectView()
}

final class OtherCard: NSView {
    let other = Glass.makeOverlayPanel(content: otherView)
}'
# Every host on a line counts: a glassed panel does not cover a popover after it.
expect_fail two-hosts-one-line popup-host 'final class DemoMenuPanel: NSPanel { let card = Glass.makeOverlayPanel(content: rows) }; let pop = NSPopover()'
# Each NativePopupHost(panel:) call is checked against the panel it constructs.
expect_fail two-native-hosts-one-line popup-host 'final class GoodPanel: NSPanel { let card = Glass.makeOverlayPanel(content: rows) }
final class BarePanel: NSPanel {}
final class DemoPicker { let a = NativePopupHost(panel: GoodPanel()); let b = NativePopupHost(panel: BarePanel()) }'
expect_pass top-level-native-host 'final class GoodPanel: NSPanel { let card = Glass.makeOverlayPanel(content: rows) }
let popup = NativePopupHost(panel: GoodPanel())'
# A nested panel is its own type: a same-named panel in another type does not cover it.
expect_fail nested-same-name popup-host 'enum A { final class DemoMenuPanel: NSPanel { let card = NSVisualEffectView() } }
enum B { final class DemoMenuPanel: NSPanel { let card = Glass.makeOverlayPanel(content: rows) } }'
expect_pass wrapped-native-host 'final class GoodPanel: NSPanel { let card = Glass.makeOverlayPanel(content: rows) }
final class DemoPicker {
    let popup = NativePopupHost(panel:
        GoodPanel())
}'
expect_pass nested-panel-glass 'final class DemoPicker {
    final class DemoMenuPanel: NSPanel { let card = Glass.makeOverlayPanel(content: rows) }
    let popup = NativePopupHost(panel: DemoMenuPanel())
}'
# A host call that wraps after its `(` is still a host.
expect_fail wrapped-native-call popup-host 'final class DemoPicker {
    let popup = NativePopupHost(
        panel: NativePopupPanel(identifier: "cmux.demo"))
    let card = NSVisualEffectView()
}'
expect_fail wrapped-adopt-call popup-host '        popup.panel.adoptPopupStyle(
            card: NSVisualEffectView())'
# A panel named by its path in the file is that nested panel.
expect_pass qualified-nested-panel 'enum Panels { final class RowsPanel: NSPanel { let card = Glass.makeOverlayPanel(content: rows) } }
final class DemoPicker {
    let popup = NativePopupHost(panel: Panels.RowsPanel())
}'
# A panel class whose declaration wraps after its `:` is that panel.
expect_pass wrapped-class-decl 'final class DemoMenuPanel:
    NSPanel {
    let card = Glass.makeOverlayPanel(content: rows)
}'
expect_fail host-call-sibling-glass popup-host 'final class BadPicker {
    private let popup = NativePopupHost(panel: NativePopupPanel(identifier: "cmux.bad"))
    func show() { popup.panel.adoptPopupStyle(card: NSVisualEffectView()) }
}

final class OtherCard: NSView {
    let other = Glass.makeOverlayPanel(content: otherView) // "{" in a comment
    let url = "https://example.com/{"
}'
expect_fail nested-type-glass popup-host 'final class BadMenuPanel: NSPanel {
    let card = NSVisualEffectView()
    private struct UnusedPreview {
        let glass = Glass.makeOverlayPanel(content: otherView)
    }
}'
expect_fail host-call-nested-glass popup-host 'final class BadPicker {
    private let popup = NativePopupHost(panel: NativePopupPanel(identifier: "cmux.bad"))
    func show() { popup.panel.adoptPopupStyle(card: NSVisualEffectView()) }
    enum Preview {
        static func card() -> NSView { Glass.makeOverlayPanel(content: otherView) }
    }
}'
expect_fail top-level-host-type-glass popup-host 'popup.panel.adoptPopupStyle(card: plainView)
final class OtherCard: NSView {
    let other = Glass.makeOverlayPanel(content: otherView)
}'

expect_pass glass '        let panel = Glass.makeOverlayPanel(content: body, cornerRadius: 10)'
expect_pass glass-menu-host 'final class DemoPickerPanel: ContentChildPanel {
    let card = Glass.makeOverlayPanel(content: rows)
}'
expect_pass menu-glass-host '        let card = Glass.makeMenuPanel(content: body)
        popup.panel.adoptPopupStyle(card: card)'
expect_pass host-comment '/// Shows it in a NativePopupHost(panel:) like the others.'
expect_pass host-inline-comment '        let card = makeCard() /* NativePopupHost(panel: x) or NSPopover() */'
# A brace in a comment or string does not end the host's body.
expect_pass brace-in-raw-string 'final class DemoMenuPanel: NSPanel {
    let pattern = #"{"}"\#"}"#
    let card = Glass.makeOverlayPanel(content: rows)
}'
expect_pass brace-in-interpolation 'final class DemoMenuPanel: NSPanel {
    let label = "\(flag ? "}" : "")"
    let card = Glass.makeOverlayPanel(content: rows)
}'
expect_pass brace-in-comment 'final class DemoMenuPanel: NSPanel { /* } */
    let label = "}"
    let card = Glass.makeOverlayPanel(content: rows)
}'
# The host's own body: a method of the host type, an extension of the panel class, or the panel
# class a NativePopupHost(panel:) call constructs.
expect_pass host-method-glass 'final class DemoPopover {
    private let popup = NativePopupHost(panel: NativePopupPanel(identifier: "cmux.demo"))
    func show() {
        let card = Glass.makeOverlayPanel(content: body, cornerRadius: 10)
        popup.panel.adoptPopupStyle(card: card)
    }
}'
expect_pass menu-extension-glass 'final class DemoMenuPanel: NSPanel {}

extension DemoMenuPanel {
    func build() { adoptPopupStyle(card: Glass.makeMenuPanel(content: rows)) }
}'
expect_pass hosted-panel-glass 'final class DemoHost {
    private func makePopup() -> NativePopupHost {
        NativePopupHost(panel: DemoRowsPanel(onPick: { id in pick(id) }))
    }
}

final class DemoRowsPanel: ContentChildPanel {
    init(onPick: @escaping (String) -> Void) {
        super.init()
        adoptPopupStyle(card: Glass.makeOverlayPanel(content: rows))
    }
}'
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

# A host whose glass GLASS_FROM puts in another file fails once that file stops building it.
palette="$tmp/Packages/macOS/CmuxNext/Sources/CmuxNextPalette"
mkdir -p "$palette"
rm -f "$src"/*.swift "$stale"/*.swift
printf '%s\n' 'final class PalettePanel: ActiveAppKeyPanel {}' > "$palette/PalettePanel.swift"
expect_palette_fail() {
  printf '%s\n' "$1" > "$palette/PaletteContentView.swift"
  if out="$(python3 -I "$CHECK" "$tmp")"; then
    echo "check-overlay-glass.test: a palette without its glass passed ($2)"; echo "$out"; exit 1
  fi
  grep -q "PalettePanel.swift:1: \[popup-host\]" <<<"$out" || { echo "check-overlay-glass.test: PalettePanel not named ($2)"; echo "$out"; exit 1; }
}
expect_palette_fail 'final class PaletteContentView: NSView {
    let glass = NSVisualEffectView()
}' "no glass"
# The mapped file's glass must be the named type's own: a helper's beside it, or a type nested in
# it, does not count.
expect_palette_fail 'final class PaletteContentView: NSView {
    let glass = NSVisualEffectView()
}
final class PalettePreviewHelper {
    let other = Glass.makeOverlayPanel(cornerRadius: 4)
}' "glass in a sibling type"
expect_palette_fail 'final class PaletteContentView: NSView {
    let glass = NSVisualEffectView()
    struct Unused { let other = Glass.makeOverlayPanel(cornerRadius: 4) }
}' "glass in a nested type"
printf '%s\n' 'final class PaletteContentView: NSView {
    let glass = Glass.makeOverlayPanel(cornerRadius: PaletteLayout.cornerRadius)
}' > "$palette/PaletteContentView.swift"
out="$(python3 -I "$CHECK" "$tmp")" || { echo "check-overlay-glass.test: the palette on its glass failed"; echo "$out"; exit 1; }

# GLASS_FROM covers the host type it names, not the whole file: another host there is checked.
printf '%s\n' 'final class PalettePanel: ActiveAppKeyPanel {}
final class PaletteHelpTip {
    let pop = NSPopover()
}' > "$palette/PalettePanel.swift"
if out="$(python3 -I "$CHECK" "$tmp")"; then
  echo "check-overlay-glass.test: an unmapped host in a mapped file passed"; echo "$out"; exit 1
fi
grep -q "PalettePanel.swift:3: \[popup-host\]" <<<"$out" || { echo "check-overlay-glass.test: the unmapped host not named"; echo "$out"; exit 1; }

# In the whole repo (a root holding this script), an entry whose file is gone is stale.
printf '%s\n' 'final class PalettePanel: ActiveAppKeyPanel {}' > "$palette/PalettePanel.swift"
mkdir -p "$tmp/scripts/cmux-next"
: > "$tmp/scripts/cmux-next/check-overlay-glass.py"
if out="$(python3 -I "$CHECK" "$tmp")"; then
  echo "check-overlay-glass.test: a deleted host's entry passed"; echo "$out"; exit 1
fi
grep -q "ServerMenuBarController.swift:1: \[popup-host\] stale allowance" <<<"$out" || { echo "check-overlay-glass.test: the deleted host's entry not named stale"; echo "$out"; exit 1; }
rm -f "$tmp/scripts/cmux-next/check-overlay-glass.py"

# A teammate's surfaces (Lawrence R48) are never flagged: an opaque fill there passes.
rm -f "$src"/*.swift
r48="$tmp/Packages/macOS/CmuxNext/Sources/CmuxNextDesignTokens/Windows"
mkdir -p "$r48"
printf '%s\n' '        layer?.backgroundColor = Palette.elevatedBackground.cgColor' > "$r48/ThemeTokens+Surface.swift"
out="$(python3 -I "$CHECK" "$tmp")" || { echo "check-overlay-glass.test: a teammate surface was flagged"; echo "$out"; exit 1; }
rm -rf "$r48"

# A card window whose glass another file builds passes while that file builds it, and fails when not.
server="$tmp/Packages/macOS/CmuxNext/Sources/CmuxNextServer"
mkdir -p "$server/Views"
printf '%s\n' 'public final class AddServerCardPanel: NSPanel {}' > "$server/Views/AddServerCardPanel.swift"
printf '%s\n' 'final class ServerHostView: NSView { let backdrop = OverlaySurfaceView(material: nil) }' > "$server/ServerHostView.swift"
out="$(python3 -I "$CHECK" "$tmp")" || { echo "check-overlay-glass.test: the mapped card window failed"; echo "$out"; exit 1; }
printf '%s\n' 'final class ServerHostView: NSView { let backdrop = NSView() }' > "$server/ServerHostView.swift"
if out="$(python3 -I "$CHECK" "$tmp")"; then
  echo "check-overlay-glass.test: a mapped card window with no glass passed"; echo "$out"; exit 1
fi
grep -q "AddServerCardPanel.swift:1: \[surface-window\]" <<<"$out" || { echo "check-overlay-glass.test: the mapped card window not named"; echo "$out"; exit 1; }
# A mapped file that declares no surface window any more is stale.
printf '%s\n' 'public final class AddServerCardHost: NSView {}' > "$server/Views/AddServerCardPanel.swift"
if out="$(python3 -I "$CHECK" "$tmp")"; then
  echo "check-overlay-glass.test: a stale SURFACE_GLASS_FROM entry passed"; echo "$out"; exit 1
fi
grep -q "\[surface-window\] stale allowance" <<<"$out" || { echo "check-overlay-glass.test: the stale entry not named"; echo "$out"; exit 1; }
rm -rf "$server"

echo "check-overlay-glass.test: ok"
