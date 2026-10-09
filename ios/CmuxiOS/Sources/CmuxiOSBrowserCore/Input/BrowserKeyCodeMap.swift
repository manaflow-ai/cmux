/// USB HID keyboard usages (`UIKey.keyCode` raw values) to DOM `code` and,
/// for keys that type nothing, DOM `key` names.
public struct BrowserKeyCodeMap: Hashable, Sendable {
    public init() {}

    public func code(forHIDUsage usage: Int) -> String? {
        switch usage {
        case 0x04...0x1d: return "Key" + String(UnicodeScalar(UInt8(usage - 0x04) + 65))
        case 0x1e...0x26: return "Digit" + String(usage - 0x1d)
        case 0x27: return "Digit0"
        case 0x3a...0x45: return "F" + String(usage - 0x39)
        default: return Self.named[usage]?.code
        }
    }

    /// The DOM `key` of a non-printing key (`Enter`, `ArrowLeft`), else nil.
    public func key(forHIDUsage usage: Int) -> String? {
        if (0x3a...0x45).contains(usage) { return "F" + String(usage - 0x39) }
        return Self.named[usage]?.key
    }

    private static let named: [Int: (code: String, key: String?)] = [
        0x28: ("Enter", "Enter"), 0x29: ("Escape", "Escape"), 0x2a: ("Backspace", "Backspace"), 0x2b: ("Tab", "Tab"),
        0x2c: ("Space", nil), 0x2d: ("Minus", nil), 0x2e: ("Equal", nil), 0x2f: ("BracketLeft", nil),
        0x30: ("BracketRight", nil), 0x31: ("Backslash", nil), 0x33: ("Semicolon", nil), 0x34: ("Quote", nil),
        0x35: ("Backquote", nil), 0x36: ("Comma", nil), 0x37: ("Period", nil), 0x38: ("Slash", nil),
        0x39: ("CapsLock", "CapsLock"), 0x49: ("Insert", "Insert"), 0x4a: ("Home", "Home"), 0x4b: ("PageUp", "PageUp"),
        0x4c: ("Delete", "Delete"), 0x4d: ("End", "End"), 0x4e: ("PageDown", "PageDown"), 0x4f: ("ArrowRight", "ArrowRight"),
        0x50: ("ArrowLeft", "ArrowLeft"), 0x51: ("ArrowDown", "ArrowDown"), 0x52: ("ArrowUp", "ArrowUp"),
        0xe0: ("ControlLeft", "Control"), 0xe1: ("ShiftLeft", "Shift"), 0xe2: ("AltLeft", "Alt"), 0xe3: ("MetaLeft", "Meta"),
        0xe4: ("ControlRight", "Control"), 0xe5: ("ShiftRight", "Shift"), 0xe6: ("AltRight", "Alt"), 0xe7: ("MetaRight", "Meta"),
    ]
}
