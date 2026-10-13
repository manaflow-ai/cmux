#if os(iOS)
import SwiftUI

/// Layout metrics shared with ChatGPT, Claude and Grok on iOS 26 (see cnx-ios/design/SPEC.md).
public struct CnxMetrics: Sendable {
    public var gutter: CGFloat = 16
    public var glassButton: CGFloat = 44
    public var composerRadius: CGFloat = 22
    public var cardRadius: CGFloat = 20
    public var sidebarWidthFraction: CGFloat = 0.82
    public var sidebarCardRadius: CGFloat = 44

    public init() {}
}

/// Motion used across the app. Springs mirror the system defaults the reference apps use.
public struct CnxMotion: Sendable {
    public var sidebar = Animation.spring(response: 0.38, dampingFraction: 0.86)
    public var press = Animation.spring(response: 0.25, dampingFraction: 0.7)
    public var content = Animation.smooth(duration: 0.3)

    public init() {}
}

/// Colors. Chrome is neutral like the AI apps; cmux-next contributes only its
/// neutral foreground accent and the ANSI status hues.
public struct CnxPalette: Sendable {
    public var background = Color(uiColor: .systemBackground)
    public var groupedBackground = Color(uiColor: .systemGroupedBackground)
    public var secondaryText = Color(uiColor: .secondaryLabel)
    public var accent = Color.primary
    public var online = Color(hex: "#32D74B")
    public var offline = Color(uiColor: .tertiaryLabel)
    public var attention = Color(hex: "#F0C674")
    public var danger = Color(hex: "#FF453A")

    public init() {}
}

/// The design system entry point: `CnxTheme.standard.palette.online`.
public struct CnxTheme: Sendable {
    public var metrics = CnxMetrics()
    public var motion = CnxMotion()
    public var palette = CnxPalette()

    public init() {}

    public static let standard = CnxTheme()
}

extension Color {
    /// `#RRGGBB` or `#RRGGBBAA`. Invalid input yields gray.
    public init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        guard Scanner(string: digits).scanHexInt64(&value), digits.count == 6 || digits.count == 8 else {
            self = .gray
            return
        }
        let hasAlpha = digits.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
#endif
