/// Modifier keys held during an input event.
public struct BrowserModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let shift = BrowserModifiers(rawValue: 1)
    public static let control = BrowserModifiers(rawValue: 1 << 1)
    public static let option = BrowserModifiers(rawValue: 1 << 2)
    public static let command = BrowserModifiers(rawValue: 1 << 3)
}
