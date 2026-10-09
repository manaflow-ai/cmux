public import Foundation

/// What the user typed in the tunnel browser's address field, as a remote
/// port plus path: `5173`, `localhost:5173/app`, `http://127.0.0.1:3000/x?y`.
/// Only loopback HTTP hosts are tunnel addresses; anything else is not. The
/// loopback proxy authenticates and parses the first request head, so it cannot
/// safely forward an HTTPS/TLS handshake (the route has no certificate or
/// decrypted cookie to validate). HTTPS dev servers stay an explicit follow-up
/// instead of failing later as an opaque proxy error.
public struct WebAddress: Hashable, Sendable {
    public var port: UInt16
    public var path: String
    public var query: String?

    public init(port: UInt16, path: String = "/", query: String? = nil) {
        self.port = port
        self.path = path
        self.query = query
    }

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// Whether a browser URL names the exit machine rather than a public
    /// destination. Keep this predicate shared with the UIKit navigation
    /// delegate so wildcard localhost names accepted by the parser are not
    /// treated as external links in subframes.
    public static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return loopbackHosts.contains(normalized) || normalized.hasSuffix(".localhost")
    }

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let port = UInt16(trimmed), port > 0 {
            self.init(port: port)
            return
        }
        let candidate = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URL(string: candidate) else { return nil }
        self.init(url: url)
    }

    /// A loopback HTTP URL as a tunnel address.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http",
              let host = url.host, Self.isLoopbackHost(host) else { return nil }
        let port = url.port ?? 80
        guard let value = UInt16(exactly: port), value > 0 else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        self.init(port: value, path: url.path.isEmpty ? "/" : url.path, query: components?.percentEncodedQuery)
    }

    public var display: String { "localhost:\(port)\(path == "/" ? "" : path)" }
}
