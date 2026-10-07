import Foundation

/// Stable id of one transfer, chosen by the client (doubles as idempotency key).
public struct TransferID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { rawValue = UUID().uuidString.lowercased() }

    public var description: String { rawValue }
}
