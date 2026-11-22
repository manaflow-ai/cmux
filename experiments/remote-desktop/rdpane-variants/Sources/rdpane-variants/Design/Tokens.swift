import AppKit

/// Chrome colors. The values are copied from the cmux-next design tokens
/// (ThemeTokens.derive over the default dark terminal theme, and over a
/// neutral light theme); this prototype does not link the design module.
/// No blue: selection, focus and hover are the foreground at low alpha.
struct Tokens {
    let isDark: Bool
    let windowBackground: NSColor
    let stripBackground: NSColor
    let elevatedBackground: NSColor
    let textPrimary: NSColor
    let textSecondary: NSColor
    let textTertiary: NSColor
    let textOnPrimary: NSColor
    let hoverFill: NSColor
    let selectionFill: NSColor
    let segmentSelected: NSColor
    let badgeFill: NSColor
    let separator: NSColor
    let glassTint: NSColor
    let shadow: NSColor
    let attention: NSColor
    let danger: NSColor
    let success: NSColor
    /// Proposed new token: the host's "being controlled" mark (screen edge,
    /// indicator dot). Vivid amber in both appearances, never blue.
    let controlIndicator: NSColor

    static func make(dark: Bool) -> Tokens {
        dark ? .dark : .light
    }

    private static var dark: Tokens { Tokens(
        isDark: true,
        windowBackground: NSColor(hex: 0x282C34),
        stripBackground: NSColor(hex: 0x1F2229),
        elevatedBackground: NSColor(hex: 0x373B42),
        textPrimary: NSColor(hex: 0xFFFFFF),
        textSecondary: NSColor(hex: 0xADAFB2),
        textTertiary: NSColor(hex: 0x898B8F),
        textOnPrimary: NSColor(hex: 0x282C34),
        hoverFill: NSColor(hex: 0xFFFFFF, alpha: 0.06),
        selectionFill: NSColor(hex: 0xFFFFFF, alpha: 0.10),
        segmentSelected: NSColor(hex: 0xFFFFFF, alpha: 0.18),
        badgeFill: NSColor(hex: 0xFFFFFF, alpha: 0.14),
        separator: NSColor(hex: 0xFFFFFF, alpha: 0.08),
        glassTint: NSColor(hex: 0x282C34, alpha: 0.40),
        shadow: NSColor(hex: 0x060707),
        attention: NSColor(hex: 0xF0C674),
        danger: NSColor(hex: 0xCC6666),
        success: NSColor(hex: 0xB5BD68),
        controlIndicator: NSColor(hex: 0xF2A33A)
    ) }

    private static var light: Tokens { Tokens(
        isDark: false,
        windowBackground: NSColor(hex: 0xFAFAFA),
        stripBackground: NSColor(hex: 0xEEEEEE),
        elevatedBackground: NSColor(hex: 0xF6F6F6),
        textPrimary: NSColor(hex: 0x1F2328),
        textSecondary: NSColor(hex: 0x65686B),
        textTertiary: NSColor(hex: 0x828486),
        textOnPrimary: NSColor(hex: 0xFAFAFA),
        hoverFill: NSColor(hex: 0x1F2328, alpha: 0.05),
        selectionFill: NSColor(hex: 0x1F2328, alpha: 0.08),
        segmentSelected: NSColor(hex: 0xFFFFFF),
        badgeFill: NSColor(hex: 0x1F2328, alpha: 0.10),
        separator: NSColor(hex: 0x1F2328, alpha: 0.07),
        glassTint: NSColor(hex: 0xFAFAFA, alpha: 0.30),
        shadow: NSColor(hex: 0x262626),
        attention: NSColor(hex: 0xA0844D),
        danger: NSColor(hex: 0xC25555),
        success: NSColor(hex: 0x888E4E),
        controlIndicator: NSColor(hex: 0xF2A33A)
    ) }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Spacing and radii (the design module's compact density values).
enum Metrics {
    static let space2: CGFloat = 4
    static let space3: CGFloat = 6
    static let space4: CGFloat = 8
    static let space5: CGFloat = 12
    static let space6: CGFloat = 16
    static let panelCornerRadius: CGFloat = 10
    static let itemCornerRadius: CGFloat = 6
    static let tabStripHeight: CGFloat = 28
    static let tabHeight: CGFloat = 24
}
