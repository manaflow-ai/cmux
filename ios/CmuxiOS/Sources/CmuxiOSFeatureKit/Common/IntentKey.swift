import Foundation

/// A client-chosen idempotency key for one intent. Replaying an intent with
/// the same key has no further effect at the owner.
public struct IntentKey: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    /// A fresh random key.
    public init() { rawValue = UUID().uuidString.lowercased() }

    public var description: String { rawValue }
}
