/// Validates the ordered cmux-lite handshake and ready-session conversation.
public struct SessionStateMachine: Sendable {
    /// Whether this state machine represents the connecting client or host.
    public let role: Role

    /// The current externally observable session phase.
    public private(set) var phase: Phase = .idle

    private var lastSentMessageID: UInt64 = 0
    private var lastReceivedMessageID: UInt64 = 0
    private var handshakeMessageID: UInt64?
    private var pendingSentPings: Set<UInt64> = []
    private var pendingReceivedPings: Set<UInt64> = []

    /// Creates an idle state machine for one side of a session.
    ///
    /// - Parameter role: The side whose sends and receives will be validated.
    public init(role: Role) {
        self.role = role
    }

    /// Records that transport establishment has started.
    ///
    /// - Throws: ``Violation/unexpectedLifecycleEvent`` unless the phase is
    ///   ``Phase/idle``.
    public mutating func beginConnecting() throws {
        guard phase == .idle else {
            try fail(.unexpectedLifecycleEvent)
        }
        phase = .connecting
    }

    /// Records that the underlying transport is ready for protocol messages.
    ///
    /// - Throws: ``Violation/unexpectedLifecycleEvent`` unless the phase is
    ///   ``Phase/connecting``.
    public mutating func transportDidConnect() throws {
        guard phase == .connecting else {
            try fail(.unexpectedLifecycleEvent)
        }
        phase = .handshaking
    }

    /// Validates and records a message sent by this side.
    ///
    /// Call this from the session's serialized owner immediately before its
    /// transport write. A later write failure should call
    /// ``transportDidClose()``.
    ///
    /// - Parameter message: The message about to be sent.
    /// - Throws: A fatal ``Violation``. The phase becomes ``Phase/closed(_:)``.
    public mutating func recordSent(_ message: WireMessage) throws {
        try validateEnvelope(message, direction: .sent)
        try apply(message, direction: .sent)
        lastSentMessageID = message.messageID
    }

    /// Validates and records a message received from the peer.
    ///
    /// - Parameter message: The next decoded message in wire order.
    /// - Throws: A fatal ``Violation``. The phase becomes ``Phase/closed(_:)``.
    public mutating func recordReceived(_ message: WireMessage) throws {
        try validateEnvelope(message, direction: .received)
        try apply(message, direction: .received)
        lastReceivedMessageID = message.messageID
    }

    /// Records transport end without a protocol `close` message.
    ///
    /// This operation is idempotent. An existing explicit or protocol-violation
    /// close reason is preserved.
    public mutating func transportDidClose() {
        guard !phase.isClosed else {
            return
        }
        phase = .closed(.transportEnded)
        clearPendingState()
    }

    /// The two roles in a cmux-lite session.
    public enum Role: Equatable, Sendable {
        /// The peer that initiates the handshake with `hello`.
        case client

        /// The peer that accepts `hello` and responds with `welcome`.
        case server
    }

    /// The ordered lifecycle phases of one protocol session.
    public enum Phase: Equatable, Sendable {
        /// No transport attempt has started.
        case idle

        /// The underlying transport is being established.
        case connecting

        /// The transport is ready and `hello`/`welcome` is incomplete.
        case handshaking

        /// The handshake succeeded with the given opaque session identifier.
        case ready(sessionID: String)

        /// The session ended and cannot accept more events.
        case closed(Closure)

        fileprivate var isClosed: Bool {
            if case .closed = self {
                return true
            }
            return false
        }
    }

    /// Why a state machine entered its terminal phase.
    public enum Closure: Equatable, Sendable {
        /// This side sent an explicit close reason.
        case local(WireMessage.Close.Reason)

        /// The peer sent an explicit close reason.
        case remote(WireMessage.Close.Reason)

        /// The byte stream ended without an explicit close message.
        case transportEnded

        /// A local or remote protocol invariant failed.
        case protocolViolation(Violation)
    }

    /// Fatal protocol and lifecycle violations.
    public enum Violation: Error, Equatable, Sendable {
        /// A lifecycle method was called from the wrong phase.
        case unexpectedLifecycleEvent

        /// A message uses a version this implementation does not support.
        case unsupportedVersion

        /// A message ID is zero or does not increase for its sender.
        case invalidMessageID

        /// A message type is invalid for the current role, direction, or phase.
        case unexpectedMessage

        /// A response is missing, invents, or repeats a request correlation.
        case invalidCorrelation

        /// Required handshake metadata is empty or unreasonably large.
        case invalidHandshakeMetadata
    }

    private enum Direction: Equatable {
        case sent
        case received
    }

    private mutating func validateEnvelope(
        _ message: WireMessage,
        direction: Direction
    ) throws {
        guard message.version == WireMessage.currentVersion else {
            try fail(.unsupportedVersion)
        }

        let previousID = switch direction {
        case .sent: lastSentMessageID
        case .received: lastReceivedMessageID
        }
        guard message.messageID > previousID else {
            try fail(.invalidMessageID)
        }
    }

    private mutating func apply(
        _ message: WireMessage,
        direction: Direction
    ) throws {
        if case .close(let close) = message.body {
            try applyClose(message, close: close, direction: direction)
            return
        }

        if case .protocolError = message.body {
            try applyProtocolError(message, direction: direction)
            return
        }

        switch phase {
        case .handshaking:
            try applyHandshake(message, direction: direction)
        case .ready:
            try applyReadyMessage(message, direction: direction)
        case .idle, .connecting, .closed:
            try fail(.unexpectedMessage)
        }
    }

    private mutating func applyHandshake(
        _ message: WireMessage,
        direction: Direction
    ) throws {
        switch (role, direction, message.body) {
        case (.client, .sent, .hello(let hello)):
            guard handshakeMessageID == nil else {
                try fail(.unexpectedMessage)
            }
            guard message.replyTo == nil else {
                try fail(.invalidCorrelation)
            }
            guard Self.isValidMetadata(hello.clientName, maximumUTF8Bytes: 64),
                  Self.isValidMetadata(hello.nonce, maximumUTF8Bytes: 256)
            else {
                try fail(.invalidHandshakeMetadata)
            }
            handshakeMessageID = message.messageID

        case (.server, .received, .hello(let hello)):
            guard handshakeMessageID == nil else {
                try fail(.unexpectedMessage)
            }
            guard message.replyTo == nil else {
                try fail(.invalidCorrelation)
            }
            guard Self.isValidMetadata(hello.clientName, maximumUTF8Bytes: 64),
                  Self.isValidMetadata(hello.nonce, maximumUTF8Bytes: 256)
            else {
                try fail(.invalidHandshakeMetadata)
            }
            handshakeMessageID = message.messageID

        case (.server, .sent, .welcome(let welcome)):
            try acceptWelcome(message, welcome: welcome)

        case (.client, .received, .welcome(let welcome)):
            try acceptWelcome(message, welcome: welcome)

        default:
            try fail(.unexpectedMessage)
        }
    }

    private mutating func acceptWelcome(
        _ message: WireMessage,
        welcome: WireMessage.Welcome
    ) throws {
        guard let handshakeMessageID,
              message.replyTo == handshakeMessageID
        else {
            try fail(.invalidCorrelation)
        }
        guard Self.isValidMetadata(welcome.sessionID, maximumUTF8Bytes: 256),
              Self.isValidMetadata(welcome.nonce, maximumUTF8Bytes: 256)
        else {
            try fail(.invalidHandshakeMetadata)
        }
        phase = .ready(sessionID: welcome.sessionID)
        self.handshakeMessageID = nil
    }

    private mutating func applyReadyMessage(
        _ message: WireMessage,
        direction: Direction
    ) throws {
        switch (direction, message.body) {
        case (.sent, .ping):
            guard message.replyTo == nil else {
                try fail(.invalidCorrelation)
            }
            pendingSentPings.insert(message.messageID)

        case (.received, .ping):
            guard message.replyTo == nil else {
                try fail(.invalidCorrelation)
            }
            pendingReceivedPings.insert(message.messageID)

        case (.sent, .pong):
            guard let replyTo = message.replyTo,
                  pendingReceivedPings.remove(replyTo) != nil
            else {
                try fail(.invalidCorrelation)
            }

        case (.received, .pong):
            guard let replyTo = message.replyTo,
                  pendingSentPings.remove(replyTo) != nil
            else {
                try fail(.invalidCorrelation)
            }

        default:
            try fail(.unexpectedMessage)
        }
    }

    private mutating func applyClose(
        _ message: WireMessage,
        close: WireMessage.Close,
        direction: Direction
    ) throws {
        guard phase == .handshaking || phase.isReady,
              message.replyTo == nil
        else {
            try fail(.unexpectedMessage)
        }
        phase = .closed(
            direction == .sent ? .local(close.reason) : .remote(close.reason)
        )
        clearPendingState()
    }

    private mutating func applyProtocolError(
        _ message: WireMessage,
        direction: Direction
    ) throws {
        guard phase == .handshaking || phase.isReady else {
            try fail(.unexpectedMessage)
        }

        if let replyTo = message.replyTo {
            let lastPeerMessageID = switch direction {
            case .sent: lastReceivedMessageID
            case .received: lastSentMessageID
            }
            guard replyTo > 0, replyTo <= lastPeerMessageID else {
                try fail(.invalidCorrelation)
            }
        }

        phase = .closed(
            direction == .sent
                ? .local(.protocolViolation)
                : .remote(.protocolViolation)
        )
        clearPendingState()
    }

    private static func isValidMetadata(
        _ value: String,
        maximumUTF8Bytes: Int
    ) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumUTF8Bytes
    }

    private mutating func clearPendingState() {
        handshakeMessageID = nil
        pendingSentPings.removeAll(keepingCapacity: false)
        pendingReceivedPings.removeAll(keepingCapacity: false)
    }

    private mutating func fail(_ violation: Violation) throws -> Never {
        if !phase.isClosed {
            phase = .closed(.protocolViolation(violation))
            clearPendingState()
        }
        throw violation
    }
}

private extension SessionStateMachine.Phase {
    var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }
}
