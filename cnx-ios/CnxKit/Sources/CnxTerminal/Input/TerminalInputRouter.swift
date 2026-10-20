import Foundation

/// Decides what each input step sends to Ghostty (plans/cmux-next/ios-keyboard.md,
/// decisions D5, KB2): hardware Ctrl, Alt (as Meta) and special keys go to the
/// key encoder; plain printable hardware keys and the software keyboard go
/// through the text system, so input methods keep working; marked text is
/// only drawn; the key bar's sticky Ctrl and Alt apply to the next key from
/// either keyboard. Adapted from CmuxiOSTerminal for cnx-ios. Pure: no UIKit, no Ghostty; the view runs the actions.
public struct TerminalInputRouter: Sendable {
    public var sticky = TerminalStickyModifiers()
    /// Option sends Meta (ESC prefix) instead of typing its symbol
    /// (setting `ios.terminal.optionAsMeta`, default true).
    public var optionAsMeta = true
    /// An input method holds marked text: every key belongs to it.
    public private(set) var markedText: String?

    public init() {}

    /// What a hardware key press does.
    public enum Press: Equatable, Sendable {
        /// UIKit handles it (text system, input method, app commands).
        case system
        /// The router sent it; the release goes to `pressEnded`.
        case handled([TerminalInputAction])
    }

    // MARK: Hardware keyboard

    /// A hardware key went down. `characters` is the text the key types with
    /// its modifiers, `unmodified` the text without any modifier.
    public mutating func pressBegan(usage: UInt16, mods: TerminalKeyMods, characters: String,
                                    unmodified: String) -> Press {
        // App commands (Command) and input methods come first.
        if markedText != nil || mods.contains(.command) { return .system }
        var mods = mods
        if !optionAsMeta { mods.remove(.alternate) }
        let special = TerminalHIDUsage.isSpecial(usage)
        // Unmodified Backspace stays with the text system, which repeats it
        // and lets an input method take it; `deleteBackward` sends the key.
        if usage == TerminalHIDUsage.backspace, mods.isEmpty { return .system }
        guard special || mods.contains(.control) || mods.contains(.alternate) else { return .system }
        let event = keyEvent(usage: usage, mods: mods, characters: characters, unmodified: unmodified, special: special)
        return .handled([.key(event)])
    }

    /// The release of a press the router handled.
    public func pressEnded(_ handled: [TerminalInputAction]) -> [TerminalInputAction] {
        handled.compactMap { action in
            guard case .key(let event) = action, event.isPress else { return nil }
            return .key(event.released)
        }
    }

    private func keyEvent(usage: UInt16, mods: TerminalKeyMods, characters: String, unmodified: String,
                          special: Bool) -> TerminalKeyEvent {
        let unshifted = unmodified.lowercased().unicodeScalars.first?.value ?? 0
        // Ctrl and Alt combos give the encoder the key's own text, not the
        // Option symbol or the control character UIKit made (Ctrl-C is `c`
        // plus ctrl; Alt-x is ESC x). Shift with Alt uppercases letters only:
        // the layout's shifted symbols are unknown without Option (a known
        // limit). Special keys carry no text.
        let text: String? = if special {
            nil
        } else if mods.contains(.control) || mods.contains(.alternate) {
            mods.contains(.shift) ? unmodified.uppercased() : unmodified
        } else {
            characters
        }
        return TerminalKeyEvent(keyCode: TerminalHIDUsage.ghosttyKeyCode(usage), mods: mods, text: text,
                                unshiftedCodepoint: special ? 0 : unshifted)
    }

    // MARK: Text system (software keyboard, dictation, printable hardware keys)

    /// Committed text. With a sticky modifier armed, a single key becomes a
    /// key event with that modifier; Return is the Enter key.
    public mutating func insertText(_ text: String) -> [TerminalInputAction] {
        markedText = nil
        if text == "\n" || text == "\r" { return press(usage: TerminalHIDUsage.enter, text: nil) }
        if text == "\t" { return press(usage: TerminalHIDUsage.tab, text: nil) }
        let mods = stickyMods()
        if !mods.isEmpty, text.count == 1, let character = text.first {
            let usage = TerminalHIDUsage.usage(forASCII: character) ?? 0
            let event = TerminalKeyEvent(keyCode: TerminalHIDUsage.ghosttyKeyCode(usage), mods: mods,
                                         text: text, unshiftedCodepoint: text.lowercased().unicodeScalars.first?.value ?? 0)
            return [.key(event), .key(event.released)]
        }
        return [.text(text)]
    }

    /// Backspace from the software keyboard or the text system.
    public mutating func deleteBackward() -> [TerminalInputAction] {
        press(usage: TerminalHIDUsage.backspace, text: nil)
    }

    /// The input method changed its marked text (nil or empty: cancelled).
    public mutating func setMarkedText(_ text: String?) -> [TerminalInputAction] {
        let value = text ?? ""
        markedText = value.isEmpty ? nil : value
        return [.preedit(value)]
    }

    /// The input method committed its marked text.
    public mutating func unmarkText() -> [TerminalInputAction] {
        guard let text = markedText else { return [] }
        markedText = nil
        return [.preedit(""), .text(text)]
    }

    /// A key typed into the composer while the key bar's ctrl or alt is
    /// armed or locked (SPEC M1): it goes to the terminal as that chord
    /// (`c` with ctrl is 0x03), never into the composer's text, and an armed
    /// modifier disarms. Nil: no modifier is on, or the text is not one key
    /// (a paste, dictation, Return), and the composer keeps it.
    public mutating func composerKey(_ text: String) -> [TerminalInputAction]? {
        guard sticky.isActive(.control) || sticky.isActive(.alternate), text.count == 1, text != "\n" else { return nil }
        return insertText(text)
    }

    // MARK: Key bar

    /// Arms or locks a sticky modifier (key bar `ctrl` / `alt`) at `time`.
    public mutating func tapSticky(_ modifier: TerminalStickyModifiers.Modifier, at time: TimeInterval) {
        sticky.tap(modifier, at: time)
    }

    /// Press and release of a physical key with the sticky modifiers plus `extra`.
    public mutating func key(usage: UInt16, extra: TerminalKeyMods = []) -> [TerminalInputAction] {
        var mods = stickyMods()
        mods.formUnion(extra)
        let event = TerminalKeyEvent(keyCode: TerminalHIDUsage.ghosttyKeyCode(usage), mods: mods)
        return [.key(event), .key(event.released)]
    }

    /// A control chord such as ^C: the letter's key with Control (sticky Alt still applies).
    public mutating func control(_ letter: Character) -> [TerminalInputAction] {
        let usage = TerminalHIDUsage.usage(forASCII: letter) ?? 0
        var mods = stickyMods()
        mods.insert(.control)
        let text = String(letter).lowercased()
        let event = TerminalKeyEvent(keyCode: TerminalHIDUsage.ghosttyKeyCode(usage), mods: mods, text: text,
                                     unshiftedCodepoint: text.unicodeScalars.first?.value ?? 0)
        return [.key(event), .key(event.released)]
    }

    /// Press and release of one key with the sticky modifiers.
    private mutating func press(usage: UInt16, text: String?) -> [TerminalInputAction] {
        let event = TerminalKeyEvent(keyCode: TerminalHIDUsage.ghosttyKeyCode(usage), mods: stickyMods(), text: text)
        return [.key(event), .key(event.released)]
    }

    private mutating func stickyMods() -> TerminalKeyMods {
        let used = sticky.consume()
        var mods: TerminalKeyMods = []
        if used.control { mods.insert(.control) }
        if used.alternate { mods.insert(.alternate) }
        return mods
    }
}
