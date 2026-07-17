import Foundation
import Network

/// Implements cmux-tui's native newline-delimited JSON protocol over a Unix socket.
public actor UnixSocketTransport: CmuxTransport {
    private let path: String
    // NWConnection requires a dispatch queue for protocol event delivery; actor isolation owns all state.
    private let eventQueue = DispatchQueue(
        label: "com.cmux.CmuxLite.UnixSocketTransport",
        qos: .userInteractive
    )
    private var connection: NWConnection?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var receiveBuffer = Data()

    /// Creates a transport for one Unix domain socket path.
    /// - Parameter path: The filesystem path of the cmux-tui socket.
    public init(path: String) {
        self.path = path
    }

    /// Opens the Unix domain socket without an authentication preamble.
    public func connect() async throws {
        guard connection == nil else {
            throw CmuxProtocolError.transportState(
                String(
                    localized: "transport.state.already_connected",
                    defaultValue: "Already connected",
                    bundle: .module
                )
            )
        }

        let connection = NWConnection(to: .unix(path: path), using: .tcp)
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

    /// Sends one UTF-8 JSON object followed by the native newline delimiter.
    /// - Parameter data: The encoded JSON object without framing.
    public func send(_ data: Data) async throws {
        guard let connection else {
            throw CmuxProtocolError.transportState(Self.notConnectedMessage)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw CmuxProtocolError.malformedPayload(
                String(
                    localized: "transport.payload.outbound_not_utf8",
                    defaultValue: "Outbound JSON is not UTF-8",
                    bundle: .module
                )
            )
        }

        var line = data
        line.append(0x0A)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: line,
                contentContext: .defaultMessage,
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

    /// Receives one complete non-empty JSON line while retaining later lines for the next call.
    /// - Returns: One UTF-8 JSON object without its newline delimiter.
    public func receive() async throws -> Data {
        guard connection != nil else {
            throw CmuxProtocolError.transportState(Self.notConnectedMessage)
        }

        while true {
            if let message = try nextBufferedMessage() {
                return message
            }
            receiveBuffer.append(try await receiveChunk())
        }
    }

    /// Cancels the socket connection and clears buffered framing state.
    public func close() {
        connectContinuation?.resume(throwing: CancellationError())
        connectContinuation = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: false)
    }

    private func nextBufferedMessage() throws -> Data? {
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let line = receiveBuffer[..<newline]
            receiveBuffer.removeSubrange(...newline)
            guard let text = String(data: line, encoding: .utf8) else {
                throw CmuxProtocolError.malformedPayload(
                    String(
                        localized: "transport.payload.inbound_not_utf8",
                        defaultValue: "Inbound JSON line is not UTF-8",
                        bundle: .module
                    )
                )
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return Data(trimmed.utf8)
            }
        }
        return nil
    }

    private func receiveChunk() async throws -> Data {
        guard let connection else {
            throw CmuxProtocolError.transportState(Self.notConnectedMessage)
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 64 * 1_024
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(
                        throwing: CmuxProtocolError.transportState(
                            String(
                                localized: "transport.state.unix_closed",
                                defaultValue: "Unix socket closed",
                                bundle: .module
                            )
                        )
                    )
                } else {
                    continuation.resume(
                        throwing: CmuxProtocolError.transportState(
                            String(
                                localized: "transport.state.unix_no_data",
                                defaultValue: "Unix socket receive completed without data",
                                bundle: .module
                            )
                        )
                    )
                }
            }
        }
    }

    private static var notConnectedMessage: String {
        String(
            localized: "transport.state.not_connected",
            defaultValue: "Not connected",
            bundle: .module
        )
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
