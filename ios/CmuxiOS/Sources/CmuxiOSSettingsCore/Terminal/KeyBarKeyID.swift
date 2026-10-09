/// A key of the terminal key bar as Settings stores it. The raw values are
/// the renderer's `TerminalKeyBarKey` ids (setting `ios.terminal.accessoryKeys`);
/// a test in `CmuxiOSTerminalTests` keeps the two lists equal.
public enum KeyBarKeyID: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case escape = "esc"
    case tab
    case control = "ctrl"
    case alternate = "alt"
    case left
    case down
    case up
    case right
    case tilde = "~"
    case slash = "/"
    case pipe = "|"
    case dash = "-"
    case paste
    case hideKeyboard = "hide-keyboard"

    public var id: String { rawValue }

    /// The renderer's default bar, in order.
    public static let defaultOrder: [KeyBarKeyID] = allCases
}
