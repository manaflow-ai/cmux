public import UIKit

/// Colors for the app shell and feature screens (tab bar, sidebar, lists,
/// status). Ink and gray only, like `HomePalette`: selection is the label
/// color, never blue. Status hues are muted system colors used only for
/// small glyphs, never fills behind text.
public enum ShellPalette {
    /// Selected tab and sidebar item: ink in light mode, paper in dark mode.
    public static let selection = UIColor.label
    public static let unselected = UIColor.secondaryLabel
    public static let background = UIColor.systemBackground
    public static let groupedBackground = UIColor.systemGroupedBackground
    public static let cellBackground = UIColor.secondarySystemGroupedBackground
    public static let primaryText = UIColor.label
    public static let secondaryText = UIColor.secondaryLabel
    public static let badgeFill = UIColor.label
    public static let badgeText = UIColor.systemBackground

    /// Status glyph colors (workspace and host state).
    public static let statusRunning = UIColor.systemGreen
    public static let statusWaiting = UIColor.systemOrange
    public static let statusFailed = UIColor.systemRed
    public static let statusIdle = UIColor.tertiaryLabel

    /// The "mock data" ribbon on placeholder screens: a quiet gray chip.
    public static let mockChipFill = UIColor.tertiarySystemFill
    public static let mockChipText = UIColor.secondaryLabel
}
