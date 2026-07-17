import Foundation

/// Carries platform-neutral keyboard input for terminal key encoding.
public struct CmuxTerminalKeyEvent: Sendable, Equatable {
    /// The printable value or platform key name.
    public let key: String

    /// Whether Control is held.
    public let control: Bool

    /// Whether Option/Alt is held.
    public let option: Bool

    /// Whether Shift is held.
    public let shift: Bool

    /// Whether Command/Meta is held.
    public let command: Bool

    /// Whether an input-method composition is active.
    public let composing: Bool

    /// Creates one platform-neutral key event.
    public init(
        key: String,
        control: Bool = false,
        option: Bool = false,
        shift: Bool = false,
        command: Bool = false,
        composing: Bool = false
    ) {
        self.key = key
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
        self.composing = composing
    }

    /// Selects the character value that a platform keyboard adapter should encode.
    ///
    /// Native event systems may replace `characters` with an ASCII control character
    /// while Control is held. In that case, the unmodified value preserves the letter
    /// needed by ``terminalAction()`` to produce the corresponding control text.
    /// - Parameters:
    ///   - characters: The text after platform modifier processing.
    ///   - charactersIgnoringModifiers: The text before platform modifier processing.
    ///   - control: Whether Control is held.
    /// - Returns: The selected non-empty character value, or `nil` when none is available.
    public static func adaptedCharacters(
        characters: String?,
        charactersIgnoringModifiers: String?,
        control: Bool
    ) -> String? {
        let selected = control ? (charactersIgnoringModifiers ?? characters) : characters
        guard let selected, !selected.isEmpty else { return nil }
        return selected
    }

    /// Encodes this event using cmux's render-frontend key rules.
    /// - Returns: Text, a named key chord, or `nil` for platform/UI-only input.
    public func terminalAction() -> CmuxTerminalKeyAction? {
        guard !composing, !command, !Self.ignoredKeys.contains(key) else { return nil }
        if key == "Tab", shift, !control, !option { return .key("backtab") }
        if let named = Self.namedKeys[key] ?? Self.functionKey(key) {
            return .key(chord(named))
        }
        guard key.count == 1 else { return nil }
        if control {
            if let text = Self.controlText(key) {
                return .text((option ? "\u{1B}" : "") + text)
            }
            return .key(chord(key.lowercased()))
        }
        return .text((option ? "\u{1B}" : "") + key)
    }

    private func chord(_ value: String) -> String {
        var parts: [String] = []
        if control { parts.append("ctrl") }
        if option { parts.append("alt") }
        if shift { parts.append("shift") }
        parts.append(value)
        return parts.joined(separator: "+")
    }

    private static func functionKey(_ value: String) -> String? {
        guard value.first == "F", let number = Int(value.dropFirst()), (1...24).contains(number) else {
            return nil
        }
        return value.lowercased()
    }

    private static func controlText(_ value: String) -> String? {
        if value == " " || value == "@" || value == "2" { return "\u{0}" }
        if value == "?" { return "\u{7F}" }
        guard let scalar = value.uppercased().unicodeScalars.first,
              value.uppercased().unicodeScalars.count == 1,
              (0x41...0x5F).contains(scalar.value),
              let encoded = UnicodeScalar(scalar.value & 0x1F)
        else { return nil }
        return String(encoded)
    }

    private static let namedKeys: [String: String] = [
        "Enter": "enter",
        "Tab": "tab",
        "Escape": "escape",
        "Backspace": "backspace",
        "Delete": "delete",
        "Insert": "insert",
        "ArrowUp": "up",
        "ArrowDown": "down",
        "ArrowLeft": "left",
        "ArrowRight": "right",
        "Home": "home",
        "End": "end",
        "PageUp": "pageup",
        "PageDown": "pagedown",
    ]

    private static let ignoredKeys: Set<String> = [
        "Alt", "AltGraph", "CapsLock", "Control", "Dead", "Meta", "NumLock",
        "Process", "ScrollLock", "Shift", "Unidentified",
    ]
}
