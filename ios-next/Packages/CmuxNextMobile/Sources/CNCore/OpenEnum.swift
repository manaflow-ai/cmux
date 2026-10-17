import Foundation

/// A string-backed protocol enum that decodes values it does not know into a
/// fallback case instead of failing the whole payload. New host versions can
/// add values without breaking older phones.
public protocol OpenStringEnum: RawRepresentable, Codable, Sendable, Hashable where RawValue == String {
    static var unknownFallback: Self { get }
}

extension OpenStringEnum {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.unknownFallback
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Milliseconds since the Unix epoch, as used by every protocol timestamp.
public typealias EpochMillis = Int64

extension Date {
    public init(epochMillis: EpochMillis) {
        self.init(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
    }

    public var epochMillis: EpochMillis { EpochMillis((timeIntervalSince1970 * 1000).rounded()) }
}
