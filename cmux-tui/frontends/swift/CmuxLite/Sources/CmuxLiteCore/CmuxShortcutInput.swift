import Foundation

/// A normalized keyboard chord used as a shortcut-table key.
public struct CmuxShortcutInput: Sendable, Equatable, Hashable {
    /// The normalized key.
    public let key: CmuxShortcutKey

    /// The exact device-independent modifiers.
    public let modifiers: CmuxShortcutModifiers

    /// Creates a shortcut chord.
    /// - Parameters:
    ///   - key: The normalized character or arrow.
    ///   - modifiers: The exact modifier set.
    public init(key: CmuxShortcutKey, modifiers: CmuxShortcutModifiers) {
        self.key = key
        self.modifiers = modifiers
    }
}
