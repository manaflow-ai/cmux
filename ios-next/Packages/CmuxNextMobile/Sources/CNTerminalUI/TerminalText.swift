#if os(iOS)
import Foundation

/// User-facing strings of the terminal module. English defaults; keys match
/// the cmux iOS terminal (CmuxiOSTerminal) so translations can be shared.
enum TerminalText {
    static var keyEscape: String { String(localized: "terminal.key.escape", defaultValue: "Escape") }
    static var keyTab: String { String(localized: "terminal.key.tab", defaultValue: "Tab") }
    static var keyControl: String { String(localized: "terminal.key.control", defaultValue: "Control") }
    static var keyAlternate: String { String(localized: "terminal.key.alternate", defaultValue: "Alt") }
    static var keyLeft: String { String(localized: "terminal.key.left", defaultValue: "Left Arrow") }
    static var keyRight: String { String(localized: "terminal.key.right", defaultValue: "Right Arrow") }
    static var keyUp: String { String(localized: "terminal.key.up", defaultValue: "Up Arrow") }
    static var keyDown: String { String(localized: "terminal.key.down", defaultValue: "Down Arrow") }
    static var keyTilde: String { String(localized: "terminal.key.tilde", defaultValue: "Tilde") }
    static var keySlash: String { String(localized: "terminal.key.slash", defaultValue: "Slash") }
    static var keyPipe: String { String(localized: "terminal.key.pipe", defaultValue: "Vertical Bar") }
    static var keyDash: String { String(localized: "terminal.key.dash", defaultValue: "Hyphen") }
    static var keyPaste: String { String(localized: "terminal.key.paste", defaultValue: "Paste") }
    static var keyHideKeyboard: String { String(localized: "terminal.key.hideKeyboard", defaultValue: "Hide Keyboard") }
    static var keyArmed: String { String(localized: "terminal.key.armed", defaultValue: "On for the next key") }
    static var keyLocked: String { String(localized: "terminal.key.locked", defaultValue: "Locked") }
    static var stickyHint: String { String(localized: "terminal.key.stickyHint", defaultValue: "Double-tap to lock.") }
    static var keycapEscape: String { String(localized: "terminal.keycap.escape", defaultValue: "esc") }
    static var keycapTab: String { String(localized: "terminal.keycap.tab", defaultValue: "tab") }
    static var keycapControl: String { String(localized: "terminal.keycap.control", defaultValue: "ctrl") }
    static var keycapAlternate: String { String(localized: "terminal.keycap.alternate", defaultValue: "alt") }
    static var terminalLabel: String { String(localized: "terminal.a11y.label", defaultValue: "Terminal") }

    static var listTitle: String { String(localized: "terminal.list.title", defaultValue: "Terminals") }
    static var newTerminal: String { String(localized: "terminal.list.new", defaultValue: "New Terminal") }
    static var closeTerminal: String { String(localized: "terminal.list.close", defaultValue: "Close") }
    static var running: String { String(localized: "terminal.list.running", defaultValue: "Running") }
    static var exited: String { String(localized: "terminal.list.exited", defaultValue: "Exited") }
    static var emptyTitle: String { String(localized: "terminal.list.empty.title", defaultValue: "No Terminals") }
    static var emptyMessage: String {
        String(localized: "terminal.list.empty.message", defaultValue: "Open a terminal on your Mac from here.")
    }
    static var offlineTitle: String { String(localized: "terminal.list.offline.title", defaultValue: "Not Connected") }
    static var offlineMessage: String {
        String(localized: "terminal.list.offline.message", defaultValue: "Terminals appear when your Mac is connected.")
    }
    static var copy: String { String(localized: "terminal.menu.copy", defaultValue: "Copy") }
    static var paste: String { String(localized: "terminal.menu.paste", defaultValue: "Paste") }
    static var selectAll: String { String(localized: "terminal.menu.selectAll", defaultValue: "Select All") }
    static var increaseFontSize: String { String(localized: "terminal.menu.increaseFontSize", defaultValue: "Larger Text") }
    static var decreaseFontSize: String { String(localized: "terminal.menu.decreaseFontSize", defaultValue: "Smaller Text") }
    static var resetFontSize: String { String(localized: "terminal.menu.resetFontSize", defaultValue: "Reset Text Size") }
    static var reconnecting: String { String(localized: "terminal.status.reconnecting", defaultValue: "Reconnecting…") }
    static var processExited: String { String(localized: "terminal.status.exited", defaultValue: "Process exited") }
    static var more: String { String(localized: "terminal.menu.more", defaultValue: "More") }
}
#endif
