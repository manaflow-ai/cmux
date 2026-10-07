public import UIKit

/// Spacing for shell and feature screens, on a 4 pt grid. Text sizes come
/// from Dynamic Type styles (`ShellTypography`), never fixed points.
public enum ShellMetrics {
    public static let sideInset: CGFloat = 16
    public static let rowVerticalPadding: CGFloat = 10
    public static let rowSpacing: CGFloat = 4
    public static let statusGlyphSize: CGFloat = 10
    public static let chipCornerRadius: CGFloat = 6
    public static let chipHorizontalPadding: CGFloat = 8
    public static let chipVerticalPadding: CGFloat = 3
    public static let headerSpacing: CGFloat = 8
    /// The width at which iPad shows the sidebar instead of the tab bar.
    public static let sidebarMinimumWidth: CGFloat = 700
}
