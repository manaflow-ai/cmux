public import Foundation

/// What the user typed in the tunnel browser's address field, as a remote
/// port plus path: `5173`, `localhost:5173/app`, `http://127.0.0.1:3000/x?y`.
/// Only loopback hosts are tunnel addresses; anything else is not.
public struct WebAddress: Hashable, Sendable {
    public var port: UInt16
    public var path: String
    public var query: String?

    public init(port: UInt16, path: String = "/", query: String? = nil) {
        self.port = port
        self.path = path
        self.query = query
    }

    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

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

    /// A loopback http(s) URL as a tunnel address.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), Self.loopbackHosts.contains(host) || host.hasSuffix(".localhost") else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        guard let value = UInt16(exactly: port), value > 0 else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        self.init(port: value, path: url.path.isEmpty ? "/" : url.path, query: components?.percentEncodedQuery)
    }

    public var display: String { "localhost:\(port)\(path == "/" ? "" : path)" }
}
