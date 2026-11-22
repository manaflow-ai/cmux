public import UIKit

/// Spacing and sizes for Home. Row heights scale with Dynamic Type through
/// self-sizing; these are the minimums at the default size.
public enum HomeMetrics {
    public static let sideInset: CGFloat = 16
    public static let bubbleMaxWidthFraction: CGFloat = 0.76
    public static let bubbleCornerRadius: CGFloat = 18
    public static let bubbleHorizontalPadding: CGFloat = 12
    public static let bubbleVerticalPadding: CGFloat = 8
    /// Gap between bubbles of one author run, and between runs.
    public static let runGap: CGFloat = 2
    public static let authorGap: CGFloat = 10
    public static let composerMinHeight: CGFloat = 36
}

/// List density prototypes (DEV switch). Lawrence picks one.
public enum HomeListDensity: String, CaseIterable, Sendable {
    /// Two-line preview, 52 pt avatar (the familiar chat list).
    case comfortable
    /// One-line preview, 40 pt avatar.
    case compact
    /// Pinned Chiefs as a grid of large avatars above a compact list.
    case pinnedGrid

    public var avatarSize: CGFloat {
        switch self {
        case .comfortable: 52
        case .compact: 40
        case .pinnedGrid: 40
        }
    }

    public var previewLines: Int {
        switch self {
        case .comfortable: 2
        case .compact, .pinnedGrid: 1
        }
    }
}
