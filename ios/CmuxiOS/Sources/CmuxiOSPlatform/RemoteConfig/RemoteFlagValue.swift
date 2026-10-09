import Foundation

/// One remote flag value. Encoded as a bare JSON bool, integer or string.
public enum RemoteFlagValue: Hashable, Sendable, Codable {
    case bool(Bool)
    case int(Int)
    case string(String)

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}
