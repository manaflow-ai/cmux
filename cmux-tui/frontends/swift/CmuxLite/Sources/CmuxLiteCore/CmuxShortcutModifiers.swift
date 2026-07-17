import Foundation

/// Device-independent modifier flags used by the cmux-lite shortcut table.
public struct CmuxShortcutModifiers: OptionSet, Sendable, Hashable {
    /// The raw modifier mask.
    public let rawValue: UInt8

    /// Creates a modifier mask.
    /// - Parameter rawValue: The raw modifier bits.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The Command key.
    public static let command = CmuxShortcutModifiers(rawValue: 1 << 0)

    /// The Control key.
    public static let control = CmuxShortcutModifiers(rawValue: 1 << 1)

    /// The Option key.
    public static let option = CmuxShortcutModifiers(rawValue: 1 << 2)

    /// The Shift key.
    public static let shift = CmuxShortcutModifiers(rawValue: 1 << 3)
}
