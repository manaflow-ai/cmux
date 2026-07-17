import Foundation

/// Creates attachment clients that use the same endpoint as the control client.
public struct ConfiguredCmuxProtocolClientFactory: CmuxProtocolClientFactory {
    private let endpoint: CmuxConnectionEndpoint

    /// Creates a factory for one resolved endpoint.
    /// - Parameter endpoint: The Unix socket or WebSocket endpoint shared by every client.
    public init(endpoint: CmuxConnectionEndpoint) {
        self.endpoint = endpoint
    }

    /// Creates a disconnected client with endpoint-appropriate framing.
    /// - Returns: A fresh protocol client.
    public func makeClient() -> CmuxProtocolClient {
        CmuxProtocolClient(transport: endpoint.makeTransport())
    }
}
