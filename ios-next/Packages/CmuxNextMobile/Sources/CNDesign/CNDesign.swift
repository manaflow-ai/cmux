#if canImport(UIKit)
public import SwiftUI
public import UIKit

/// cmux-next colors for iOS.
///
/// Values come from the cmux-next ThemeTokens derived from the default Ghostty
/// theme pair "Apple System Colors" (Packages/Shared/CmuxTheme, resolved in
/// plans/cmux-next/spec-proposals/visuals/design-tokens.md). The rule carried
/// over from the Mac: no accent hue. Selection, hover and focus are the
/// foreground at low alpha; the only hue is `highlight`, used for the agent
/// composer's send button and switches. Outgoing message bubbles are ink, as in
/// the existing cmux iOS Home (ios/CmuxiOS/Sources/CmuxiOSDesign/HomePalette.swift).
public struct CNPalette: Sendable {
    public let background = CNPalette.pair(dark: 0x1E1E1E, light: 0xFEFFFF)
    public let sidebar = CNPalette.pair(dark: 0x272727, light: 0xF5F6F6)
    public let chrome = CNPalette.pair(dark: 0x292929, light: 0xF5F6F6)
    public let elevated = CNPalette.pair(dark: 0x2F2F2F, light: 0xFFFFFF)
    public let control = CNPalette.pair(dark: 0x353535, light: 0xEDEEEE)
    public let pressed = CNPalette.pair(dark: 0x393939, light: 0xE7E8E8)
    public let selection = CNPalette.pair(dark: 0x595959, light: 0xD5D6D6)
    public let separator = CNPalette.pair(dark: 0x3B3B3B, light: 0xE2E3E3)
    public let hairline = CNPalette.alphaPair(dark: (0xFFFFFF, 0.08), light: (0x000000, 0.07))
    public let fillHover = CNPalette.alphaPair(dark: (0xFFFFFF, 0.06), light: (0x000000, 0.05))
    public let fillSelection = CNPalette.alphaPair(dark: (0xFFFFFF, 0.10), light: (0x000000, 0.08))
    public let fillBadge = CNPalette.alphaPair(dark: (0xFFFFFF, 0.14), light: (0x000000, 0.10))
    public let textPrimary = CNPalette.pair(dark: 0xFFFFFF, light: 0x000000)
    public let textSecondary = CNPalette.pair(dark: 0xAAAAAA, light: 0x616161)
    public let textTertiary = CNPalette.pair(dark: 0x888888, light: 0x7F8080)
    public let icon = CNPalette.pair(dark: 0xBCBCBC, light: 0x4C4D4D)
    /// Ink: the foreground used where other apps would use an accent color.
    public let ink = CNPalette.pair(dark: 0xFFFFFF, light: 0x000000)
    public let highlight = CNPalette.pair(dark: 0x0869CB, light: 0x0869CB)
    public let danger = CNPalette.pair(dark: 0xFF6152, light: 0xDD1919)
    public let warning = CNPalette.pair(dark: 0xFFD60A, light: 0x856E00)
    public let success = CNPalette.pair(dark: 0x32D74B, light: 0x008220)
    public let attention = CNPalette.pair(dark: 0xCDAC08, light: 0xAC9007)
    public let outgoingBubble = CNPalette.pair(dark: 0xE6E6E6, light: 0x1F1F1F)
    public let outgoingText = CNPalette.pair(dark: 0x0F0F0F, light: 0xFAFAFA)
    public let incomingBubble = CNPalette.pair(dark: 0x2C2C2C, light: 0xEBEBEB)
    public let incomingText = CNPalette.pair(dark: 0xFFFFFF, light: 0x000000)
    public let chiefAvatar = CNPalette.pair(dark: 0x4D453D, light: 0xDBD1C4)
    public let personAvatar = CNPalette.pair(dark: 0x4D4D4D, light: 0xCCCCCC)
    /// Terminal surface follows the Ghostty theme background.
    public let terminalBackground = CNPalette.pair(dark: 0x1E1E1E, light: 0xFEFFFF)
    /// Nine low-saturation group hues for user content (avatars, workspace groups).
    public let groupHues: [UIColor] = [0x8E8A84, 0x7F8C8D, 0x8C8579, 0x7D8471, 0x7A8796, 0x8A7F93, 0x93807F, 0x8B8F7A, 0x7C8A86]
        .map { CNPalette.rgb($0) }

    public init() {}

    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func pair(dark: UInt32, light: UInt32) -> UIColor {
        let d = rgb(dark), l = rgb(light)
        return UIColor { $0.userInterfaceStyle == .dark ? d : l }
    }

    static func alphaPair(dark: (UInt32, CGFloat), light: (UInt32, CGFloat)) -> UIColor {
        let d = rgb(dark.0, alpha: dark.1), l = rgb(light.0, alpha: light.1)
        return UIColor { $0.userInterfaceStyle == .dark ? d : l }
    }

    /// Stable group hue for an identifier (avatars without photos).
    public func groupHue(for id: String) -> UIColor {
        var hash: UInt32 = 2166136261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return groupHues[Int(hash % UInt32(groupHues.count))]
    }
}

/// Spacing, radii and motion shared by every screen. iOS sizes follow the HIG
/// (17 pt body); the 2 pt grid and continuous corners come from cmux-next.
public struct CNMetrics: Sendable {
    public let sideInset: CGFloat = 16
    public let grid: CGFloat = 2
    public let itemRadius: CGFloat = 10
    public let cardRadius: CGFloat = 16
    public let composerRadius: CGFloat = 22
    public let controlHeight: CGFloat = 44
    public init() {}
}

public struct CNMotion: Sendable {
    /// Default UI spring (cmux-next "move": response 0.20 scaled for touch).
    public let move = Animation.spring(response: 0.35, dampingFraction: 0.9)
    public let appear = Animation.spring(response: 0.3, dampingFraction: 0.9)
    public let fade = Animation.easeOut(duration: 0.12)
    public init() {}

    @MainActor public var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
}

/// Entry point: `CNTheme.shared.palette.background`, or `.cn(\.background)` in SwiftUI.
public struct CNTheme: Sendable {
    public let palette = CNPalette()
    public let metrics = CNMetrics()
    public let motion = CNMotion()
    public init() {}
    public static let shared = CNTheme()
}

extension ShapeStyle where Self == Color {
    /// `Color.cn(\.textSecondary)` or `.foregroundStyle(.cn(\.textSecondary))`.
    public static func cn(_ key: KeyPath<CNPalette, UIColor>) -> Color {
        Color(uiColor: CNTheme.shared.palette[keyPath: key])
    }
}
#endif
