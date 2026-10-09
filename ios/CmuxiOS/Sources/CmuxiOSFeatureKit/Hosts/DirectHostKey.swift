import Foundation

/// The host's X25519 public key a direct address is pinned to (lane B4):
/// 32 bytes, kept as standard base64. It is public, so it syncs with the
/// host record; the carrier refuses a host that cannot prove it.
public struct DirectHostKey: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    /// Accepts standard or URL-safe base64 of exactly 32 bytes, padding
    /// optional, and normalizes to standard padded base64.
    public init?(rawValue: String) {
        var text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text.append("=") }
        guard let data = Data(base64Encoded: text), data.count == 32 else { return nil }
        self.rawValue = data.base64EncodedString()
    }

    public var description: String { rawValue }
}
