/// What Return does in the composer (e4-compose.md 3): the software
/// keyboard's Return types a newline and the Send button sends; on a
/// hardware keyboard Return and Command-Return send, Shift-Return and
/// Option-Return type a newline.
public struct ComposerReturnRule: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public enum Action: Hashable, Sendable {
        case send
        case newline
    }

    public var hardwareKeyboard: Bool

    public init(hardwareKeyboard: Bool) {
        self.hardwareKeyboard = hardwareKeyboard
    }

    public func action(for modifiers: Modifiers) -> Action {
        guard hardwareKeyboard else { return .newline }
        if modifiers.contains(.command) { return .send }
        if modifiers.contains(.shift) || modifiers.contains(.option) { return .newline }
        return .send
    }
}
