import Foundation
import Network

/// Implements low-latency WebSocket text messages with `NWConnection`.
public actor NetworkWebSocketTransport: CmuxTransport {
    private let url: URL
    // NWConnection requires a dispatch queue for protocol event delivery; actor isolation owns all state.
    private let eventQueue = DispatchQueue(
        label: "com.cmux.CmuxLite.NetworkWebSocketTransport",
        qos: .userInteractive
    )
    private var connection: NWConnection?
    private var connectContinuation: CheckedContinuation<Void, Error>?

    /// Creates a Network.framework WebSocket transport for an endpoint.
    /// - Parameter url: A `ws` or `wss` endpoint.
    public init(url: URL) {
        self.url = url
    }

    /// Starts the WebSocket handshake over a TCP no-delay connection.
    public func connect() async throws {
        guard connection == nil else {
            throw CmuxProtocolError.transportState("already connected")
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters: NWParameters
        if url.scheme == "wss" {
            parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcpOptions)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
        }
        let webSocketOptions = NWProtocolWebSocket.Options(.version13)
        webSocketOptions.autoReplyPing = true
        webSocketOptions.maximumMessageSize = 16 * 1_024 * 1_024
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)

        let connection = NWConnection(to: .url(url), using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleConnectionState(state) }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connectContinuation = continuation
                connection.start(queue: eventQueue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Sends one complete UTF-8 JSON object as a WebSocket text message.
    /// - Parameter data: The encoded JSON object.
    public func send(_ data: Data) async throws {
        guard connection != nil else {
            throw CmuxProtocolError.transportState("not connected")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw CmuxProtocolError.malformedPayload("outbound JSON is not UTF-8")
        }

        try await sendFrame(data, opcode: .text)
    }

    /// Sends a legal unsolicited Pong to wake cmux-tui's outbound queue drain.
    public func wakePeer() async throws {
        try await sendFrame(Data(), opcode: .pong)
        try await sendFrame(Data(), opcode: .pong)
    }

    private func sendFrame(_ data: Data, opcode: NWProtocolWebSocket.Opcode) async throws {
        guard let connection else {
            throw CmuxProtocolError.transportState("not connected")
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(
            identifier: "cmux-json",
            metadata: [metadata]
        )
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    /// Receives one complete WebSocket text message and rejects other opcodes.
    /// - Returns: The UTF-8 JSON object.
    public func receive() async throws -> Data {
        guard let connection else {
            throw CmuxProtocolError.transportState("not connected")
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, context, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let metadata = context?.protocolMetadata(
                    definition: NWProtocolWebSocket.definition
                ) as? NWProtocolWebSocket.Metadata else {
                    continuation.resume(
                        throwing: CmuxProtocolError.malformedPayload(
                            "WebSocket message is missing protocol metadata"
                        )
                    )
                    return
                }
                guard metadata.opcode == .text else {
                    continuation.resume(
                        throwing: CmuxProtocolError.unsupportedMessage(
                            "non-text WebSocket frame"
                        )
                    )
                    return
                }
                guard let data else {
                    continuation.resume(
                        throwing: CmuxProtocolError.transportState(
                            "WebSocket closed without payload"
                        )
                    )
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    /// Cancels the WebSocket connection and releases its state handler.
    public func close() {
        connectContinuation?.resume(throwing: CancellationError())
        connectContinuation = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        guard let continuation = connectContinuation else { return }
        switch state {
        case .ready:
            connectContinuation = nil
            continuation.resume()
        case let .failed(error):
            connectContinuation = nil
            connection = nil
            continuation.resume(throwing: error)
        case .cancelled:
            connectContinuation = nil
            connection = nil
            continuation.resume(throwing: CancellationError())
        case .setup, .waiting, .preparing:
            break
        @unknown default:
            break
        }
    }
}
