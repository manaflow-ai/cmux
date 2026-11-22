import AppKit

/// Paints fake application windows into a flipped view. Used for the
/// synthetic remote desktop and the mock host screen.
@MainActor
enum MockWindowPainter {
    enum Style {
        case linuxDark
        case linuxLight
        case macDark
        case macLight

        var isDark: Bool { self == .linuxDark || self == .macDark }
        var isMac: Bool { self == .macDark || self == .macLight }
        var titleBarHeight: CGFloat { isMac ? 28 : 32 }
        var titleBar: NSColor {
            switch self {
            case .linuxDark: NSColor(hex: 0x2B2D2E)
            case .linuxLight: NSColor(hex: 0xE6E4E1)
            case .macDark: NSColor(hex: 0x24262B)
            case .macLight: NSColor(hex: 0xECECEC)
            }
        }
        var body: NSColor {
            switch self {
            case .linuxDark: NSColor(hex: 0x1C1E1F)
            case .linuxLight: NSColor(hex: 0xFBFBFA)
            case .macDark: NSColor(hex: 0x282C34)
            case .macLight: NSColor(hex: 0xFFFFFF)
            }
        }
        var titleText: NSColor { isDark ? NSColor(hex: 0xD8D8D8) : NSColor(hex: 0x3A3A3A) }
    }

    /// Draws the frame, shadow and title bar; returns the content rect.
    @discardableResult
    static func paint(_ frame: NSRect, title: String, style: Style, active: Bool = true) -> NSRect {
        let radius: CGFloat = style.isMac ? 10 : 8
        let outline = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(active ? 0.45 : 0.28)
        shadow.shadowBlurRadius = active ? 24 : 14
        shadow.shadowOffset = NSSize(width: 0, height: active ? -10 : -5)
        shadow.set()
        style.body.setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        let bar = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: style.titleBarHeight)
        style.titleBar.setFill()
        bar.fill()
        NSColor.black.withAlphaComponent(style.isDark ? 0.4 : 0.08).setFill()
        NSRect(x: frame.minX, y: bar.maxY - 1, width: frame.width, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()

        let titleFont = NSFont.systemFont(ofSize: 12, weight: style.isMac ? .semibold : .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: style.titleText.withAlphaComponent(active ? 1 : 0.6)]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: bar.midX - size.width / 2, y: bar.midY - size.height / 2), withAttributes: attributes)

        if style.isMac {
            let colors: [UInt32] = active ? [0xFF5F57, 0xFEBC2E, 0x28C840] : [0x5A5C60, 0x5A5C60, 0x5A5C60]
            for (index, hex) in colors.enumerated() {
                NSColor(hex: hex).setFill()
                NSBezierPath(ovalIn: NSRect(x: frame.minX + 12 + CGFloat(index) * 20, y: bar.midY - 6, width: 12, height: 12)).fill()
            }
        } else {
            for index in 0..<3 {
                let x = frame.maxX - 22 - CGFloat(index) * 24
                (style.isDark ? NSColor(hex: 0x45484A) : NSColor(hex: 0xCFCCC8)).setFill()
                NSBezierPath(ovalIn: NSRect(x: x - 7, y: bar.midY - 7, width: 14, height: 14)).fill()
            }
        }
        return NSRect(x: frame.minX, y: bar.maxY, width: frame.width, height: frame.height - bar.height)
    }

    /// Draws monospaced lines; each line is (text, color).
    static func lines(_ lines: [(String, NSColor)], at origin: NSPoint, size: CGFloat = 12, leading: CGFloat = 17, clip: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clip).addClip()
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        for (index, line) in lines.enumerated() {
            (line.0 as NSString).draw(at: NSPoint(x: origin.x, y: origin.y + CGFloat(index) * leading),
                                      withAttributes: [.font: font, .foregroundColor: line.1])
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func text(_ string: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
        (string as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }

    static func textWidth(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
    }
}
