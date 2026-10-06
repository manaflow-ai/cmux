import Foundation

/// Localized strings of the terminal screen (en, ja; other languages await review).
enum TerminalText {
    static var keyEscape: String { String(localized: "terminal.key.escape", defaultValue: "Escape", bundle: .module) }
    static var keyTab: String { String(localized: "terminal.key.tab", defaultValue: "Tab", bundle: .module) }
    static var keyControl: String { String(localized: "terminal.key.control", defaultValue: "Control", bundle: .module) }
    static var keyAlternate: String { String(localized: "terminal.key.alternate", defaultValue: "Alt", bundle: .module) }
    static var keyLeft: String { String(localized: "terminal.key.left", defaultValue: "Left Arrow", bundle: .module) }
    static var keyRight: String { String(localized: "terminal.key.right", defaultValue: "Right Arrow", bundle: .module) }
    static var keyUp: String { String(localized: "terminal.key.up", defaultValue: "Up Arrow", bundle: .module) }
    static var keyDown: String { String(localized: "terminal.key.down", defaultValue: "Down Arrow", bundle: .module) }
    static var keyTilde: String { String(localized: "terminal.key.tilde", defaultValue: "Tilde", bundle: .module) }
    static var keySlash: String { String(localized: "terminal.key.slash", defaultValue: "Slash", bundle: .module) }
    static var keyPipe: String { String(localized: "terminal.key.pipe", defaultValue: "Vertical Bar", bundle: .module) }
    static var keyDash: String { String(localized: "terminal.key.dash", defaultValue: "Hyphen", bundle: .module) }
    static var keyPaste: String { String(localized: "terminal.key.paste", defaultValue: "Paste", bundle: .module) }
    static var keyHideKeyboard: String { String(localized: "terminal.key.hideKeyboard", defaultValue: "Hide Keyboard", bundle: .module) }
    static var keyArmed: String { String(localized: "terminal.key.armed", defaultValue: "On for the next key", bundle: .module) }
    static var keyLocked: String { String(localized: "terminal.key.locked", defaultValue: "Locked", bundle: .module) }
    static var stickyHint: String { String(localized: "terminal.key.stickyHint", defaultValue: "Double-tap to lock.", bundle: .module) }
    static var keycapEscape: String { String(localized: "terminal.keycap.escape", defaultValue: "esc", bundle: .module) }
    static var keycapTab: String { String(localized: "terminal.keycap.tab", defaultValue: "tab", bundle: .module) }
    static var keycapControl: String { String(localized: "terminal.keycap.control", defaultValue: "ctrl", bundle: .module) }
    static var keycapAlternate: String { String(localized: "terminal.keycap.alternate", defaultValue: "alt", bundle: .module) }
    static var terminalLabel: String { String(localized: "terminal.a11y.label", defaultValue: "Terminal", bundle: .module) }
}
