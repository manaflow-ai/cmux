import Foundation

/// The per-route token cookie that proves a connection to a phone loopback
/// listener comes from this app's web view (c14-web.md section 4): other
/// apps share the loopback interface and must not reach the tunnel.
public struct WebTunnelCookie: Sendable {
    public static let name = "__cmux_tunnel"

    public let value: String

    public init(value: String) {
        self.value = value
    }

    /// 256 random bits, base64url.
    public static func random() -> WebTunnelCookie {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let value = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return WebTunnelCookie(value: value)
    }

    /// The HttpOnly cookie for `localhost` (cookies ignore ports).
    public var httpCookie: HTTPCookie? {
        HTTPCookie(properties: [.name: Self.name, .value: value, .domain: "localhost", .path: "/",
                                HTTPCookiePropertyKey("HttpOnly"): "TRUE", .discard: "TRUE"])
    }

    /// Compares without an early exit.
    static func matches(_ presented: String, _ expected: String) -> Bool {
        let a = Array(presented.utf8)
        let b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
