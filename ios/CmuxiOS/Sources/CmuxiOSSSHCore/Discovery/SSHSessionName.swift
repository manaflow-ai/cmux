import Foundation

/// A session id taken from a discovery listing, safe to put on a command
/// line: 1-128 of `[A-Za-z0-9_.:-]`, not starting with `-` (so it can never
/// read as an option). Free text from the user never becomes one.
public struct SSHSessionName: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(validating raw: String) {
        guard (1...128).contains(raw.utf8.count), raw.utf8.first != UInt8(ascii: "-"),
              raw.utf8.allSatisfy(Self.isAllowed) else { return nil }
        rawValue = raw
    }

    public var description: String { rawValue }

    static func isAllowed(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
            || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: ":") || byte == UInt8(ascii: "-")
    }
}
