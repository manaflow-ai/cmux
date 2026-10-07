/// A composed prompt as surface input (e4-compose.md 2): one paste, which
/// Ghostty brackets when the program enabled bracketed paste, then one
/// Return press and release unless the user only inserts.
public struct TerminalComposedInput: Hashable, Sendable {
    public var text: String
    public var submits: Bool

    public init(text: String, submits: Bool) {
        self.text = text
        self.submits = submits
    }

    public var actions: [TerminalInputAction] {
        var actions: [TerminalInputAction] = text.isEmpty ? [] : [.paste(text)]
        if submits {
            let enter = TerminalKeyEvent(keyCode: TerminalHIDUsage.ghosttyKeyCode(TerminalHIDUsage.enter))
            actions += [.key(enter), .key(enter.released)]
        }
        return actions
    }
}
