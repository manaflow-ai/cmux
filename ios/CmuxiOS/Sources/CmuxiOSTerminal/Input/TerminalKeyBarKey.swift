import Foundation

/// A key of the terminal key bar over the software keyboard (ghostty-next
/// section 5). The raw value is the key's id in the setting
/// `ios.terminal.accessoryKeys` (an ordered list of these ids).
public enum TerminalKeyBarKey: String, CaseIterable, Sendable {
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

    /// The default bar (ghostty-next section 5).
    public static let defaultKeys: [TerminalKeyBarKey] = [
        .escape, .tab, .control, .alternate, .left, .down, .up, .right, .tilde, .slash, .pipe, .dash, .paste,
        .hideKeyboard,
    ]

    /// The keys a setting value names, in its order; unknown ids are skipped,
    /// and an empty or missing value gives the default bar.
    public static func keys(fromSetting ids: [String]?) -> [TerminalKeyBarKey] {
        let keys = (ids ?? []).compactMap(TerminalKeyBarKey.init(rawValue:))
        return keys.isEmpty ? defaultKeys : keys
    }

    /// The physical key a key bar key presses, for keys that are keys.
    var usage: UInt16? {
        switch self {
        case .escape: TerminalHIDUsage.escape
        case .tab: TerminalHIDUsage.tab
        case .left: TerminalHIDUsage.left
        case .down: TerminalHIDUsage.down
        case .up: TerminalHIDUsage.up
        case .right: TerminalHIDUsage.right
        default: nil
        }
    }

    /// The text a symbol key types.
    var symbol: String? {
        switch self {
        case .tilde, .slash, .pipe, .dash: rawValue
        default: nil
        }
    }

    /// Arrow keys repeat while held.
    var repeats: Bool {
        switch self {
        case .left, .down, .up, .right: true
        default: false
        }
    }
}
