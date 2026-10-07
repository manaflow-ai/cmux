import Foundation

/// Stable id of a machine (paired Mac, SSH host or direct address).
public struct HostID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }
}
