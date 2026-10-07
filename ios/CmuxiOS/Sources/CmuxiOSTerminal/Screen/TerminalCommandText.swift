import Foundation

/// Titles of the terminal screen's commands (Command overlay, More menu).
enum TerminalCommandText {
    static var copy: String { String(localized: "terminal.command.copy", defaultValue: "Copy", bundle: .module) }
    static var paste: String { String(localized: "terminal.command.paste", defaultValue: "Paste", bundle: .module) }
    static var selectAll: String { String(localized: "terminal.command.selectAll", defaultValue: "Select All", bundle: .module) }
    static var larger: String { String(localized: "terminal.command.larger", defaultValue: "Larger Text", bundle: .module) }
    static var smaller: String { String(localized: "terminal.command.smaller", defaultValue: "Smaller Text", bundle: .module) }
    static var actualSize: String { String(localized: "terminal.command.actualSize", defaultValue: "Actual Size", bundle: .module) }
    static var textSize: String { String(localized: "terminal.command.textSize", defaultValue: "Text Size", bundle: .module) }
    static var olderHistory: String {
        String(localized: "terminal.command.olderHistory", defaultValue: "Load Older History", bundle: .module)
    }
    static var historyLoading: String { String(localized: "terminal.history.loading", defaultValue: "Loading…", bundle: .module) }
    static var historyUnavailable: String {
        String(localized: "terminal.history.unavailable", defaultValue: "Not available from this Mac", bundle: .module)
    }
    static var close: String { String(localized: "terminal.command.close", defaultValue: "Close Terminal", bundle: .module) }
    static var more: String { String(localized: "terminal.command.more", defaultValue: "More", bundle: .module) }
}
