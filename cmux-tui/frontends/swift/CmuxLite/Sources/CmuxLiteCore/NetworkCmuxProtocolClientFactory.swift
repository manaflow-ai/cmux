import Foundation

/// Creates protocol clients backed only by the Network.framework transport.
public struct NetworkCmuxProtocolClientFactory: CmuxProtocolClientFactory {
    private let url: URL

    /// Creates a factory for an endpoint.
    /// - Parameter url: The `ws` or `wss` cmux-tui URL.
    public init(url: URL) {
        self.url = url
    }

    /// Creates a disconnected Network.framework protocol client.
    /// - Returns: A disconnected protocol client.
    public func makeClient() -> CmuxProtocolClient {
        CmuxProtocolClient(transport: NetworkWebSocketTransport(url: url))
    }
}
