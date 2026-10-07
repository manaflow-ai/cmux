import Foundation

/// The list's sections, in display order.
public enum CloudMachineSectionKind: String, Hashable, Sendable {
    /// Running, or on the way up, down or out.
    case active
    case paused
    /// A failed machine (the owner recorded an error).
    case failed
}
