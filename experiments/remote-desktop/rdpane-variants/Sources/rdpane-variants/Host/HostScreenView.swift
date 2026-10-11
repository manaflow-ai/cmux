import AppKit

/// A mock of the HOST Mac's screen, drawn inside the demo window. The
/// prototype never draws over the real display: border, pill and menus all
/// live inside this view. Fixture content, so its text is not localized.
final class HostScreenView: NSView {
    static let menuBarHeight: CGFloat = 24

    private let dark: Bool
    private let showsIndicatorItem: Bool
    private let consentLayout: Bool

    init(dark: Bool, showsIndicatorItem: Bool, consentLayout: Bool) {
        self.dark = dark
        self.showsIndicatorItem = showsIndicatorItem
        self.consentLayout = consentLayout
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The front cmux window; the consent sheet hangs from its title bar.
    var cmuxWindowFrame: NSRect {
        consentLayout ? NSRect(x: 230, y: 84, width: 640, height: 450) : NSRect(x: 60, y: 70, width: 640, height: 430)
    }

    /// Where the remote desktop menu bar item sits (variant I3).
    func indicatorItemFrame(width: CGFloat) -> NSRect {
        let clockWidth = MockWindowPainter.textWidth(Self.clock, size: 13, weight: .medium)
        let x = width - 12 - clockWidth - 14 - CGFloat(Self.statusSymbols.count) * 28 - 34
        return NSRect(x: x, y: 2, width: 32, height: 20)
    }

    private static let clock = "Fri 2 Oct  14:32"
    private static let statusSymbols = ["battery.75percent", "wifi", "magnifyingglass", "switch.2"]

    override func draw(_ dirtyRect: NSRect) {
        paintWallpaper()
        MockWindowPainter.paint(NSRect(x: 640, y: 230, width: 400, height: 320), title: "Release notes", style: .macLight, active: false)
            .insetBy(dx: 18, dy: 14)
            .paintDocumentLines()
        paintCmuxWindow(cmuxWindowFrame)
        paintDock()
        paintMenuBar()
    }

    private func paintWallpaper() {
        let colors = dark
            ? [NSColor(hex: 0x6A5546), NSColor(hex: 0x352D33), NSColor(hex: 0x1C1B20)]
            : [NSColor(hex: 0xEDE5DA), NSColor(hex: 0xD3C8BB), NSColor(hex: 0xB8AEA3)]
        NSGradient(colors: colors)?.draw(in: bounds, angle: -65)
    }

    private func paintCmuxWindow(_ frame: NSRect) {
        let content = MockWindowPainter.paint(frame, title: "cmux", style: .macDark, active: true)
        let sidebar = NSRect(x: content.minX, y: content.minY, width: 160, height: content.height)
        NSColor(hex: 0x1F2229).setFill()
        sidebar.fill()
        let rows = ["build-linux", "rd-host", "notes", "bench"]
        for (index, row) in rows.enumerated() {
            let rect = NSRect(x: sidebar.minX + 8, y: sidebar.minY + 10 + CGFloat(index) * 28, width: sidebar.width - 16, height: 24)
            if index == 1 {
                NSColor.white.withAlphaComponent(0.10).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            MockWindowPainter.text(row, at: NSPoint(x: rect.minX + 10, y: rect.minY + 4), size: 12.5,
                                   color: NSColor.white.withAlphaComponent(index == 1 ? 0.95 : 0.65))
        }
        let terminal = NSRect(x: sidebar.maxX, y: content.minY, width: content.width - sidebar.width, height: content.height)
        let plain = NSColor(hex: 0xD4D4D4)
        let prompt = NSColor(hex: 0x9CC56E)
        MockWindowPainter.lines([
            ("$ git status --short", prompt),
            (" M host/encode.c", plain),
            (" M host/pacer.c", plain),
            ("$ make test", prompt),
            ("ok   pacer_spacing        (0.21 s)", plain),
            ("ok   nack_window          (0.08 s)", plain),
            ("ok   refine_after_idle    (0.34 s)", plain),
            ("3 passed", plain),
            ("$ █", prompt),
        ], at: NSPoint(x: terminal.minX + 14, y: terminal.minY + 12), clip: terminal)
    }

    private func paintDock() {
        let dock = NSRect(x: bounds.midX - 190, y: bounds.maxY - 62, width: 380, height: 54)
        (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.white.withAlphaComponent(0.42)).setFill()
        NSBezierPath(roundedRect: dock, xRadius: 18, yRadius: 18).fill()
        let colors: [UInt32] = [0x2B2F36, 0xC9A66B, 0x8A6F86, 0x6E7B72, 0xB0573D, 0x9A9A8C]
        for (index, hex) in colors.enumerated() {
            NSColor(hex: hex).setFill()
            NSBezierPath(roundedRect: NSRect(x: dock.minX + 14 + CGFloat(index) * 60, y: dock.minY + 6, width: 42, height: 42), xRadius: 10, yRadius: 10).fill()
        }
    }

    private func paintMenuBar() {
        let bar = NSRect(x: 0, y: 0, width: bounds.width, height: Self.menuBarHeight)
        (dark ? NSColor.black.withAlphaComponent(0.30) : NSColor.white.withAlphaComponent(0.45)).setFill()
        bar.fill()
        let ink = dark ? NSColor.white.withAlphaComponent(0.92) : NSColor.black.withAlphaComponent(0.85)
        var x: CGFloat = 16
        for (index, item) in ["cmux", "File", "Edit", "View", "Window", "Help"].enumerated() {
            let weight: NSFont.Weight = index == 0 ? .bold : .regular
            MockWindowPainter.text(item, at: NSPoint(x: x, y: 4), size: 13, weight: weight, color: ink)
            x += MockWindowPainter.textWidth(item, size: 13, weight: weight) + 20
        }
        let clockWidth = MockWindowPainter.textWidth(Self.clock, size: 13, weight: .medium)
        MockWindowPainter.text(Self.clock, at: NSPoint(x: bar.maxX - 12 - clockWidth, y: 4), size: 13, weight: .medium, color: ink)
        var symbolX = bar.maxX - 12 - clockWidth - 14 - 28
        for name in Self.statusSymbols.reversed() {
            drawSymbol(name, in: NSRect(x: symbolX, y: 2, width: 28, height: 20), color: ink, size: 13)
            symbolX -= 28
        }
        guard showsIndicatorItem else { return }
        let item = indicatorItemFrame(width: bounds.width)
        (dark ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.12)).setFill()
        NSBezierPath(roundedRect: item, xRadius: 6, yRadius: 6).fill()
        drawSymbol("rectangle.inset.filled.and.person.filled", in: item, color: ink, size: 13)
        NSColor(hex: 0xF2A33A).setFill()
        NSBezierPath(ovalIn: NSRect(x: item.maxX - 9, y: item.minY + 2, width: 6, height: 6)).fill()
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor, size: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let size = image.size
        let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

private extension NSRect {
    /// Gray placeholder text lines for the mock document window.
    @MainActor
    func paintDocumentLines() {
        let widths: [CGFloat] = [0.55, 0.92, 0.88, 0.95, 0.4, 0, 0.6, 0.9, 0.85, 0.93, 0.7]
        for (index, fraction) in widths.enumerated() where fraction > 0 {
            NSColor(hex: index == 0 || index == 6 ? 0x6B6B6B : 0xC8C8C8).setFill()
            let height: CGFloat = index == 0 || index == 6 ? 9 : 7
            NSBezierPath(roundedRect: NSRect(x: minX, y: minY + CGFloat(index) * 20, width: width * fraction, height: height),
                         xRadius: 3, yRadius: 3).fill()
        }
    }
}
