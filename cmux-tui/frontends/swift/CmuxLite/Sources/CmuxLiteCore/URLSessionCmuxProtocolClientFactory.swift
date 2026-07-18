import Foundation

/// Creates WebSocket protocol clients that connect to one cmux-tui endpoint.
public struct URLSessionCmuxProtocolClientFactory: CmuxProtocolClientFactory {
    private let url: URL

    /// Creates a factory for an endpoint.
    /// - Parameter url: The `ws` or `wss` cmux-tui URL.
    public init(url: URL) {
        self.url = url
    }

    /// Creates a client with its own WebSocket transport.
    /// - Returns: A disconnected protocol client.
    public func makeClient() -> CmuxProtocolClient {
        CmuxProtocolClient(transport: URLSessionWebSocketTransport(url: url))
    }
}
