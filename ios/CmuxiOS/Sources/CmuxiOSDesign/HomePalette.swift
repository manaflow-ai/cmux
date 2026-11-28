public import UIKit

/// Home colors. Ink and gray only: no blue accents (cmux-next visual rule).
/// Outgoing bubbles use an inverted fill (ink background, paper text).
public enum HomePalette {
    public static let background = UIColor.systemBackground
    public static let groupedBackground = UIColor.systemGroupedBackground
    public static let primaryText = UIColor.label
    public static let secondaryText = UIColor.secondaryLabel
    public static let tertiaryText = UIColor.tertiaryLabel
    public static let separator = UIColor.separator

    /// The accent: ink in light mode, paper in dark mode.
    public static let accent = UIColor.label

    public static let outgoingBubble = UIColor { traits in
        let contrast = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark
            ? UIColor(white: contrast ? 0.96 : 0.90, alpha: 1)
            : UIColor(white: contrast ? 0.04 : 0.12, alpha: 1)
    }

    public static let outgoingText = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.06, alpha: 1) : UIColor(white: 0.98, alpha: 1)
    }

    public static let incomingBubble = UIColor { traits in
        let contrast = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark
            ? UIColor(white: contrast ? 0.24 : 0.17, alpha: 1)
            : UIColor(white: contrast ? 0.84 : 0.92, alpha: 1)
    }

    public static let incomingText = UIColor.label

    /// Chief rows and avatars get a warm neutral, never blue.
    public static let chiefAvatar = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.30, green: 0.27, blue: 0.24, alpha: 1)
            : UIColor(red: 0.86, green: 0.82, blue: 0.77, alpha: 1)
    }

    public static let personAvatar = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.30, alpha: 1) : UIColor(white: 0.80, alpha: 1)
    }

    public static let unreadDot = UIColor.label
    public static let failure = UIColor.systemRed
    public static let pinnedBackground = UIColor.secondarySystemBackground
}
