import Foundation

/// Selects the framing and address used for one cmux-tui connection.
public enum CmuxConnectionEndpoint: Sendable, Equatable {
    /// The native newline-delimited JSON transport at a Unix domain socket path.
    case unixSocket(path: String)

    /// The WebSocket parity transport at a `ws` or `wss` URL.
    case webSocket(url: URL)

    /// Creates a fresh transport for this endpoint.
    /// - Returns: A disconnected transport using the endpoint's native framing.
    public func makeTransport() -> any CmuxTransport {
        switch self {
        case let .unixSocket(path):
            UnixSocketTransport(path: path)
        case let .webSocket(url):
            FallbackWebSocketTransport(url: url)
        }
    }
}
