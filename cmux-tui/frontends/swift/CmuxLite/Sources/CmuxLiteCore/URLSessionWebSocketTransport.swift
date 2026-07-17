import Foundation

/// Implements cmux-tui WebSocket framing with `URLSessionWebSocketTask`.
public actor URLSessionWebSocketTransport: CmuxTransport {
    private let url: URL
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    /// Creates a WebSocket transport for an endpoint.
    /// - Parameter url: A `ws` or `wss` endpoint.
    public init(url: URL) {
        self.url = url
    }

    /// Starts the WebSocket task.
    public func connect() async throws {
        guard task == nil else {
            throw CmuxProtocolError.transportState("already connected")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
    }

    /// Sends one WebSocket text frame without newline framing.
    public func send(_ data: Data) async throws {
        guard let task else {
            throw CmuxProtocolError.transportState("not connected")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CmuxProtocolError.malformedPayload("outbound JSON is not UTF-8")
        }
        try await task.send(.string(text))
    }

    /// Receives one WebSocket text frame and rejects binary frames.
    public func receive() async throws -> Data {
        guard let task else {
            throw CmuxProtocolError.transportState("not connected")
        }

        switch try await task.receive() {
        case let .string(text):
            return Data(text.utf8)
        case .data:
            throw CmuxProtocolError.unsupportedMessage("binary WebSocket frame")
        @unknown default:
            throw CmuxProtocolError.unsupportedMessage("unknown WebSocket frame")
        }
    }

    /// Cancels the WebSocket task with a normal closure code.
    public func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }
}
