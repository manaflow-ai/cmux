public import UIKit

/// Dynamic Type styles for shell and feature screens.
@MainActor
public enum ShellTypography {
    public static var rowTitle: UIFont { UIFont.preferredFont(forTextStyle: .body) }
    public static var rowSubtitle: UIFont { UIFont.preferredFont(forTextStyle: .subheadline) }
    public static var caption: UIFont { UIFont.preferredFont(forTextStyle: .caption1) }
    public static var chip: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .caption2)
        return UIFont.systemFont(ofSize: base.pointSize, weight: .semibold)
    }
}
