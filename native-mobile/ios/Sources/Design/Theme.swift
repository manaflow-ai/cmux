import SwiftUI
import UIKit

/// cmux-next's palette, kept minimal: ink and gray chrome over system
/// materials, the terminal's own default colors for terminal surfaces, and
/// one warm attention color. No blue accents (cmux-next iOS rule); links and
/// primary actions use the label color.
enum Theme {
    /// cmux-tui's default terminal colors (vt-state `colors`).
    static let terminalBackground = UIColor(red: 0x13 / 255, green: 0x14 / 255, blue: 0x15 / 255, alpha: 1)
    static let terminalForeground = UIColor(red: 0xd8 / 255, green: 0xd9 / 255, blue: 0xda / 255, alpha: 1)

    /// App background: true black in dark mode (like Claude and ChatGPT),
    /// grouped white in light mode.
    static let background = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .black : .systemBackground
    })
    static let elevated = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 0.11, alpha: 1) : UIColor(white: 0.96, alpha: 1)
    })
    static let separator = Color(uiColor: .separator)
    static let ink = Color.primary
    static let secondaryInk = Color.secondary
    static let tertiaryInk = Color(uiColor: .tertiaryLabel)

    /// Agent attention (blocked, needs input): cmux-next's attention token.
    static let attention = Color(red: 0.98, green: 0.62, blue: 0.24)
    static let danger = Color(red: 0.94, green: 0.33, blue: 0.31)
    static let success = Color(red: 0.36, green: 0.80, blue: 0.47)
    static let working = Color(red: 0.55, green: 0.70, blue: 0.98)

    /// iMessage-style bubbles in the feed.
    static let bubbleOutgoing = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 0.20, alpha: 1) : UIColor(white: 0.90, alpha: 1)
    })
    static let bubbleIncoming = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 0.13, alpha: 1) : UIColor(white: 0.95, alpha: 1)
    })

    static let monoFont = Font.system(.footnote, design: .monospaced)
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let cornerRadius: CGFloat = 22
    static let rowCornerRadius: CGFloat = 14
}

extension View {
    /// A Liquid Glass capsule control, the standard chrome for floating
    /// buttons (Claude, ChatGPT and Grok all float their toolbar controls).
    func glassCircle(size: CGFloat = 44) -> some View {
        frame(width: size, height: size)
            .glassEffect(.regular.interactive(), in: .circle)
    }

    func glassCapsule() -> some View {
        glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// Haptics used across the app (Claude has a haptics toggle in Settings).
@MainActor
enum Haptics {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }
    static func tap() { guard enabled else { return }; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func soft() { guard enabled else { return }; UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func success() { guard enabled else { return }; UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { guard enabled else { return }; UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func selection() { guard enabled else { return }; UISelectionFeedbackGenerator().selectionChanged() }
}
