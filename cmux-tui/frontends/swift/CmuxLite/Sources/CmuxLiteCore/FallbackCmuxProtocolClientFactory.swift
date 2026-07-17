import Foundation

/// Creates protocol clients that prefer Network.framework with URLSession fallback.
public struct FallbackCmuxProtocolClientFactory: CmuxProtocolClientFactory {
    private let url: URL

    /// Creates a factory for an endpoint.
    /// - Parameter url: The `ws` or `wss` cmux-tui URL.
    public init(url: URL) {
        self.url = url
    }

    /// Creates a disconnected client with the fallback WebSocket transport.
    /// - Returns: A disconnected protocol client.
    public func makeClient() -> CmuxProtocolClient {
        CmuxProtocolClient(transport: FallbackWebSocketTransport(url: url))
    }
}
