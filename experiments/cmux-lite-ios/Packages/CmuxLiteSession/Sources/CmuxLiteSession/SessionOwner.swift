internal import Foundation
public import CmuxLiteProtocol

/// Owns one cmux-lite protocol conversation over an injected byte stream.
public actor SessionOwner {
    /// The role and deterministic handshake data for one owner.
    public enum Configuration: Equatable, Sendable {
        /// Sends this hello after the client transport connects.
        case client(hello: WireMessage.Hello)

        /// Answers a received hello with this welcome.
        case server(welcome: WireMessage.Welcome)

        fileprivate var role: SessionStateMachine.Role {
            switch self {
            case .client:
                return .client
            case .server:
                return .server
            }
        }
    }

    /// Observable lifecycle and control events emitted by the owner.
    public enum Event: Equatable, Sendable {
        /// The byte stream connected and protocol work may begin.
        case transportConnected

        /// Both sides accepted the handshake.
        case ready(sessionID: String)

        /// A peer ping was accepted and will receive an automatic pong.
        case pingReceived(messageID: UInt64)

        /// A peer pong was accepted for a locally sent ping.
        case pongReceived(replyTo: UInt64)

        /// The owner stopped because a framing, protocol, or transport failure occurred.
        case failure(Failure)

        /// The conversation reached its terminal phase.
        case closed(SessionStateMachine.Closure)
    }

    /// Failures returned by commands or emitted for asynchronous failures.
    public enum Failure: Error, Equatable, Sendable {
        /// ``start()`` was called more than once.
        case alreadyStarted

        /// A command requiring a started owner was called before ``start()``.
        case notStarted

        /// A ping was requested before the handshake completed.
        case notReady

        /// A command was attempted after the owner closed.
        case closed

        /// The finite sender ID space was exhausted.
        case messageIDExhausted

        /// The byte stream produced an invalid or oversized frame.
        case framing(FrameCodec.Failure)

        /// A decoded message violated the protocol state machine.
        case protocolViolation(SessionStateMachine.Violation)

        /// The injected byte stream failed or ended unexpectedly.
        case transport
    }

    /// The configured role for this owner.
    public let configuration: Configuration

    /// A single-consumer stream of owner events.
    public nonisolated let events: AsyncStream<Event>

    private let stream: any ByteStream
    private let codec: FrameCodec
    private let writer: SerializedByteStreamWriter
    private let eventContinuation: AsyncStream<Event>.Continuation
    private var state: SessionStateMachine
    private var decoder: FrameCodec.Decoder
    private var receiveTask: Task<Void, Never>?
    private var started = false
    private var finished = false
    private var readyWasEmitted = false
    private var nextMessageID: UInt64 = 1

    /// Creates an owner with deterministic handshake values and dependencies.
    ///
    /// - Parameters:
    ///   - configuration: The client or server handshake role.
    ///   - stream: The ordered byte stream used for this conversation.
    ///   - codec: The bounded frame encoder and decoder.
    public init(
        configuration: Configuration,
        stream: any ByteStream,
        codec: FrameCodec
    ) {
        self.configuration = configuration
        self.stream = stream
        self.codec = codec
        self.writer = SerializedByteStreamWriter(stream: stream)
        self.state = SessionStateMachine(role: configuration.role)
        self.decoder = codec.makeDecoder()

        let (events, continuation) = AsyncStream<Event>.makeStream()
        self.events = events
        self.eventContinuation = continuation
    }

    deinit {
        receiveTask?.cancel()
        eventContinuation.finish()
    }

    /// Connects the stream and starts the receive loop.
    ///
    /// A client sends its configured hello before this method returns. A
    /// server returns after it begins waiting for that hello. Use ``events``
    /// to observe the later ``ready`` event.
    ///
    /// - Throws: ``Failure/alreadyStarted`` or ``Failure/transport`` when the
    ///   stream cannot be established.
    public func start() async throws {
        guard !started else {
            throw Failure.alreadyStarted
        }
        started = true

        do {
            try state.beginConnecting()
            try await stream.connect()
            try state.transportDidConnect()
            eventContinuation.yield(.transportConnected)
            startReceiveLoop()

            if case .client(let hello) = configuration {
                try await sendMessage(body: .hello(hello), replyTo: nil)
            }
        } catch {
            await stop(failure: Self.mapFailure(error))
            throw Self.mapFailure(error)
        }
    }

    /// Returns the current validated protocol phase.
    public func currentPhase() -> SessionStateMachine.Phase {
        state.phase
    }

    /// Sends a ping and returns its locally allocated message ID.
    ///
    /// - Returns: The ID that the peer must reference in its pong.
    /// - Throws: ``Failure/notStarted``, ``Failure/notReady``,
    ///   ``Failure/closed``, or a transport failure.
    public func sendPing() async throws -> UInt64 {
        guard started else {
            throw Failure.notStarted
        }
        guard case .ready = state.phase else {
            if state.phase.isClosed {
                throw Failure.closed
            }
            throw Failure.notReady
        }

        let messageID = try allocateMessageID()
        do {
            try await sendMessage(
                messageID: messageID,
                body: .ping,
                replyTo: nil
            )
            return messageID
        } catch {
            await stop(failure: Self.mapFailure(error))
            throw Self.mapFailure(error)
        }
    }

    /// Sends an explicit close and releases the byte stream.
    ///
    /// Calling this method before ``start()`` has no effect. Repeated calls
    /// after closure are idempotent.
    ///
    /// - Parameter reason: The reason advertised to the peer.
    public func close(reason: WireMessage.Close.Reason = .normal) async {
        guard started, !finished else {
            return
        }

        guard state.phase == .handshaking || state.phase.isReady else {
            await stop()
            return
        }

        do {
            try await sendMessage(body: .close(.init(reason: reason)), replyTo: nil)
            await stop()
        } catch {
            await stop(failure: Self.mapFailure(error))
        }
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                guard let chunk = try await stream.receive() else {
                    await stop()
                    return
                }

                for message in try decoder.ingest(chunk) {
                    try await handle(message)
                    if finished {
                        return
                    }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            await stop(failure: Self.mapFailure(error))
        }
    }

    private func handle(_ message: WireMessage) async throws {
        do {
            try state.recordReceived(message)
        } catch {
            await stop(failure: Self.mapFailure(error))
            throw error
        }

        switch message.body {
        case .hello:
            guard case .server(let welcome) = configuration else {
                return
            }
            try await sendMessage(
                body: .welcome(welcome),
                replyTo: message.messageID
            )
            emitReadyIfNeeded()

        case .welcome:
            emitReadyIfNeeded()

        case .ping:
            eventContinuation.yield(.pingReceived(messageID: message.messageID))
            try await sendMessage(body: .pong, replyTo: message.messageID)

        case .pong:
            if let replyTo = message.replyTo {
                eventContinuation.yield(.pongReceived(replyTo: replyTo))
            }

        case .protocolError, .close:
            await stop()
        }
    }

    private func emitReadyIfNeeded() {
        guard !readyWasEmitted,
              case .ready(let sessionID) = state.phase
        else {
            return
        }
        readyWasEmitted = true
        eventContinuation.yield(.ready(sessionID: sessionID))
    }

    private func sendMessage(
        body: WireMessage.Body,
        replyTo: UInt64?
    ) async throws {
        try await sendMessage(
            messageID: try allocateMessageID(),
            body: body,
            replyTo: replyTo
        )
    }

    private func sendMessage(
        messageID: UInt64,
        body: WireMessage.Body,
        replyTo: UInt64?
    ) async throws {
        let message = WireMessage(
            messageID: messageID,
            replyTo: replyTo,
            body: body
        )
        let frame = try codec.encode(message)
        try state.recordSent(message)
        try await writer.send(frame)

        if case .closed = state.phase,
           case .close = body {
            return
        }
    }

    private func allocateMessageID() throws -> UInt64 {
        guard nextMessageID > 0 else {
            throw Failure.messageIDExhausted
        }
        let allocated = nextMessageID
        nextMessageID = nextMessageID == UInt64.max ? 0 : nextMessageID + 1
        return allocated
    }

    private func stop(failure: Failure? = nil) async {
        guard !finished else {
            return
        }
        finished = true

        if let failure {
            eventContinuation.yield(.failure(failure))
        }

        if !state.phase.isClosed {
            state.transportDidClose()
        }
        guard case .closed(let closure) = state.phase else {
            eventContinuation.finish()
            return
        }

        eventContinuation.yield(.closed(closure))
        eventContinuation.finish()
        receiveTask?.cancel()
        receiveTask = nil
        await writer.cancel()
        await stream.close()
    }

    private static func mapFailure(_ error: any Error) -> Failure {
        if let failure = error as? Failure {
            return failure
        }
        if let failure = error as? FrameCodec.Failure {
            return .framing(failure)
        }
        if let violation = error as? SessionStateMachine.Violation {
            return .protocolViolation(violation)
        }
        return .transport
    }
}

private extension SessionStateMachine.Phase {
    var isClosed: Bool {
        if case .closed = self {
            return true
        }
        return false
    }

    var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }
}
