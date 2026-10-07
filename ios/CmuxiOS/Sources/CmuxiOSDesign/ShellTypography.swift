public import UIKit

/// Dynamic Type styles for shell and feature screens.
@MainActor
public enum ShellTypography {
    public static var rowTitle: UIFont { UIFont.preferredFont(forTextStyle: .body) }
    public static var rowSubtitle: UIFont { UIFont.preferredFont(forTextStyle: .subheadline) }
    public static var caption: UIFont { UIFont.preferredFont(forTextStyle: .caption1) }
    /// Semibold caption 2 scaled through `UIFontMetrics`, so labels with
    /// `adjustsFontForContentSizeCategory` follow a live Dynamic Type change
    /// (a plain `systemFont(ofSize:)` carries no text style and never updates).
    public static var chip: UIFont {
        UIFontMetrics(forTextStyle: .caption2).scaledFont(for: UIFont.systemFont(ofSize: 11, weight: .semibold))
    }
}
