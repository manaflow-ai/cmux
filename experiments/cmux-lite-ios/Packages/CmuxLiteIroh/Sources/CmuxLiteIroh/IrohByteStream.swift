public import Foundation
public import CmuxLiteProtocol

/// Adapts one already-open native Iroh connection to ``ByteStream``.
public actor IrohByteStream: ByteStream {
    /// Stream lifecycle and misuse failures.
    public enum Failure: Error, Equatable, Sendable {
        /// A nonempty operation was attempted before ``connect()``.
        case notConnected

        /// A second send overlapped an existing send.
        case sendAlreadyPending

        /// A second receive overlapped an existing receive.
        case receiveAlreadyPending

        /// The native binding violated the byte-stream contract with an empty chunk.
        case emptyReceivedChunk

        /// The stream was closed and cannot be reused.
        case closed

        /// The native binding returned a classified failure.
        case native(IrohOpenFailure)

        /// The native binding returned an error without a classification.
        case unclassifiedNativeFailure
    }

    /// The lifecycle phases visible to diagnostics and tests.
    public enum State: Equatable, Sendable {
        /// The native connection exists, but the owner has not started it.
        case idle

        /// The byte stream is ready for send and receive operations.
        case connected

        /// The stream is terminal.
        case closed
    }

    private let connection: any IrohConnection
    private var state: State = .idle
    private var sendInFlight = false
    private var receiveInFlight = false

    /// Creates a stream around a native connection returned by a connector.
    ///
    /// - Parameter connection: The native bidirectional Iroh connection.
    public init(connection: any IrohConnection) {
        self.connection = connection
    }

    deinit {
        let connectionToClose = connection
        Task {
            await connectionToClose.close()
        }
    }

    /// Marks the native connection ready for byte-stream operations.
    ///
    /// Repeated calls after success are idempotent.
    ///
    /// - Throws: ``Failure/closed`` after the stream has been closed.
    public func connect() async throws {
        switch state {
        case .idle:
            state = .connected
        case .connected:
            return
        case .closed:
            throw Failure.closed
        }
    }

    /// Sends one chunk through the native Iroh connection.
    ///
    /// Empty data is a no-op. The session owner serializes nonempty sends; the
    /// adapter rejects a direct overlapping call so bytes cannot interleave.
    ///
    /// - Parameter bytes: The next byte chunk.
    /// - Throws: A lifecycle or native binding failure.
    public func send(_ bytes: Data) async throws {
        guard !bytes.isEmpty else {
            return
        }
        guard state == .connected else {
            throw state == .closed ? Failure.closed : Failure.notConnected
        }
        guard !sendInFlight else {
            throw Failure.sendAlreadyPending
        }

        sendInFlight = true
        defer { sendInFlight = false }
        do {
            try await connection.send(bytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.map(error)
        }
    }

    /// Receives one arbitrary chunk from the native Iroh connection.
    ///
    /// - Returns: A nonempty chunk, or `nil` after peer EOF.
    /// - Throws: A lifecycle, overlap, or native binding failure.
    public func receive() async throws -> Data? {
        guard state == .connected else {
            if case .closed = state {
                return nil
            }
            throw Failure.notConnected
        }
        guard !receiveInFlight else {
            throw Failure.receiveAlreadyPending
        }

        receiveInFlight = true
        defer { receiveInFlight = false }
        do {
            let bytes = try await connection.receive()
            if let bytes, bytes.isEmpty {
                throw Failure.emptyReceivedChunk
            }
            return bytes
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.map(error)
        }
    }

    /// Closes the native connection idempotently.
    public func close() async {
        guard state != .closed else {
            return
        }
        state = .closed
        await connection.close()
    }

    /// Returns the current stream lifecycle state.
    public func currentState() -> State {
        state
    }

    private static func map(_ error: any Error) -> Failure {
        if let failure = error as? Failure {
            return failure
        }
        if let failure = error as? IrohOpenFailure {
            return .native(failure)
        }
        return .unclassifiedNativeFailure
    }
}
