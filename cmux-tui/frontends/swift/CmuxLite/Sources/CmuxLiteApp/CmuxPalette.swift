import AppKit
import CmuxLiteCore

struct CmuxPalette {
    let background: NSColor
    let hoverBackground: NSColor
    let activeBackground: NSColor
    let rail: NSColor
    let border: NSColor
    let foreground: NSColor
    let activeForeground: NSColor
    let dim: NSColor
    let sidebarDim: NSColor
    let tabInactive: NSColor
    let statusBackground: NSColor
    let statusActiveBackground: NSColor

    private static let fallback = CmuxPalette(
        background: NSColor(srgbRed: 0x0C / 255, green: 0x0C / 255, blue: 0x0C / 255, alpha: 1),
        hoverBackground: NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1C / 255, alpha: 1),
        activeBackground: NSColor(srgbRed: 0x30 / 255, green: 0x30 / 255, blue: 0x30 / 255, alpha: 1),
        rail: NSColor(srgbRed: 0x87 / 255, green: 0xAF / 255, blue: 0xD7 / 255, alpha: 1),
        border: NSColor(srgbRed: 0x44 / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1),
        foreground: NSColor(srgbRed: 0xBC / 255, green: 0xBC / 255, blue: 0xBC / 255, alpha: 1),
        activeForeground: NSColor(srgbRed: 0xEE / 255, green: 0xEE / 255, blue: 0xEE / 255, alpha: 1),
        dim: NSColor(srgbRed: 0x80 / 255, green: 0x80 / 255, blue: 0x80 / 255, alpha: 1),
        sidebarDim: NSColor(srgbRed: 0x6C / 255, green: 0x6C / 255, blue: 0x6C / 255, alpha: 1),
        tabInactive: NSColor(srgbRed: 0x94 / 255, green: 0x94 / 255, blue: 0x94 / 255, alpha: 1),
        statusBackground: NSColor(srgbRed: 0x30 / 255, green: 0x30 / 255, blue: 0x30 / 255, alpha: 1),
        statusActiveBackground: NSColor(srgbRed: 0x58 / 255, green: 0x58 / 255, blue: 0x58 / 255, alpha: 1)
    )

    @MainActor private static var resolved: CmuxPalette?

    @MainActor static var tui: CmuxPalette {
        resolved ?? fallback
    }

    @MainActor static func configure(with configuration: CmuxGhosttyViewConfiguration) {
        guard let background = CmuxRenderColor(configuration.background)?.color else {
            resolved = nil
            return
        }
        let foreground = CmuxRenderColor(configuration.foreground)?.color ?? fallback.foreground
        resolved = CmuxPalette(
            background: background,
            hoverBackground: background.blended(toward: foreground, fraction: 0.08),
            activeBackground: background.blended(toward: foreground, fraction: 0.14),
            rail: fallback.rail,
            border: background.blended(toward: foreground, fraction: 0.18),
            foreground: foreground,
            activeForeground: foreground,
            dim: background.blended(toward: foreground, fraction: 0.65),
            sidebarDim: background.blended(toward: foreground, fraction: 0.52),
            tabInactive: background.blended(toward: foreground, fraction: 0.72),
            statusBackground: background,
            statusActiveBackground: background.blended(toward: foreground, fraction: 0.20)
        )
    }
}

private extension NSColor {
    func blended(toward color: NSColor, fraction: CGFloat) -> NSColor {
        usingColorSpace(.sRGB)?
            .blended(withFraction: fraction, of: color.usingColorSpace(.sRGB) ?? color)
            ?? self
    }
}
