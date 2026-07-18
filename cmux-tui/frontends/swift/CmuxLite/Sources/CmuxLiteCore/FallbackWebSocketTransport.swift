import Foundation

/// Prefers Network.framework and falls back to URLSession if connection setup fails.
public actor FallbackWebSocketTransport: CmuxTransport {
    private let url: URL
    private var activeTransport: (any CmuxTransport)?

    /// Creates a transport pair for one WebSocket endpoint.
    /// - Parameter url: A `ws` or `wss` endpoint.
    public init(url: URL) {
        self.url = url
    }

    /// Connects with Network.framework, falling back to URLSession on setup failure.
    public func connect() async throws {
        guard activeTransport == nil else {
            throw CmuxProtocolError.transportState("already connected")
        }

        let preferred = NetworkWebSocketTransport(url: url)
        do {
            try await preferred.connect()
            activeTransport = preferred
        } catch is CancellationError {
            await preferred.close()
            throw CancellationError()
        } catch {
            await preferred.close()
            let fallback = URLSessionWebSocketTransport(url: url)
            try await fallback.connect()
            activeTransport = fallback
        }
    }

    /// Sends one complete protocol message on the selected transport.
    /// - Parameter data: The encoded UTF-8 JSON object.
    public func send(_ data: Data) async throws {
        guard let activeTransport else {
            throw CmuxProtocolError.transportState("not connected")
        }
        try await activeTransport.send(data)
    }

    /// Receives one complete protocol message from the selected transport.
    /// - Returns: The encoded UTF-8 JSON object.
    public func receive() async throws -> Data {
        guard let activeTransport else {
            throw CmuxProtocolError.transportState("not connected")
        }
        return try await activeTransport.receive()
    }

    /// Wakes the selected transport's peer-side output drain.
    public func wakePeer() async throws {
        guard let activeTransport else {
            throw CmuxProtocolError.transportState("not connected")
        }
        try await activeTransport.wakePeer()
    }

    /// Closes the selected transport.
    public func close() async {
        let activeTransport = activeTransport
        self.activeTransport = nil
        await activeTransport?.close()
    }
}
