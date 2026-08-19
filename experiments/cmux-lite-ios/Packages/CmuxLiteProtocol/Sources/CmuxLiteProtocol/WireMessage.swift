internal import Foundation

/// One versioned cmux-lite control message carried inside a framed payload.
public struct WireMessage: Codable, Equatable, Sendable {
    /// The only protocol version implemented by this package.
    public static let currentVersion: UInt16 = 1

    /// A positive identifier that increases for every message from one sender.
    public let messageID: UInt64

    /// The protocol version used to encode this message.
    public let version: UInt16

    /// The initiating message ID when this message is a response.
    public let replyTo: UInt64?

    /// The typed message content.
    public let body: Body

    /// Creates a wire message.
    ///
    /// Semantic constraints such as positive IDs, correlation, and message
    /// direction are enforced by ``SessionStateMachine``.
    ///
    /// - Parameters:
    ///   - messageID: The sender's monotonically increasing message ID.
    ///   - version: The protocol version, normally ``currentVersion``.
    ///   - replyTo: The initiating message ID for a response.
    ///   - body: The typed message content.
    public init(
        messageID: UInt64,
        version: UInt16 = Self.currentVersion,
        replyTo: UInt64? = nil,
        body: Body
    ) {
        self.messageID = messageID
        self.version = version
        self.replyTo = replyTo
        self.body = body
    }

    /// The supported control-message variants.
    public enum Body: Equatable, Sendable {
        /// Begins protocol negotiation from the connecting peer.
        case hello(Hello)

        /// Accepts a `hello` and establishes a logical session.
        case welcome(Welcome)

        /// Requests a liveness response.
        case ping

        /// Responds to a `ping`.
        case pong

        /// Reports a fatal protocol error.
        case protocolError(ProtocolError)

        /// Ends a session with an explicit reason.
        case close(Close)
    }

    /// Client metadata carried by a `hello` message.
    public struct Hello: Codable, Equatable, Sendable {
        /// A diagnostic implementation name, never an authorization claim.
        public let clientName: String

        /// An opaque, freshly generated value for this handshake.
        public let nonce: String

        /// Creates client handshake metadata.
        ///
        /// - Parameters:
        ///   - clientName: A diagnostic implementation name.
        ///   - nonce: A fresh opaque handshake value.
        public init(clientName: String, nonce: String) {
            self.clientName = clientName
            self.nonce = nonce
        }

        private enum CodingKeys: String, CodingKey {
            case clientName = "client_name"
            case nonce
        }
    }

    /// Server metadata carried by a `welcome` message.
    public struct Welcome: Codable, Equatable, Sendable {
        /// The opaque identifier for the newly established logical session.
        public let sessionID: String

        /// An opaque, freshly generated server value for this handshake.
        public let nonce: String

        /// Creates server handshake metadata.
        ///
        /// - Parameters:
        ///   - sessionID: The newly established logical-session identifier.
        ///   - nonce: A fresh opaque handshake value.
        public init(sessionID: String, nonce: String) {
            self.sessionID = sessionID
            self.nonce = nonce
        }

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case nonce
        }
    }

    /// A fatal protocol error reported to the remote peer.
    public struct ProtocolError: Codable, Equatable, Sendable {
        /// The machine-readable error category.
        public let code: Code

        /// Creates a protocol-error payload.
        ///
        /// - Parameter code: The machine-readable error category.
        public init(code: Code) {
            self.code = code
        }

        /// Categories that are safe to expose across the protocol boundary.
        public enum Code: String, Codable, Equatable, Sendable {
            /// The peer requested a protocol version this implementation rejects.
            case unsupportedVersion = "unsupported_version"

            /// The peer sent bytes that do not form a valid frame or message.
            case malformedFrame = "malformed_frame"

            /// The message is not valid for the current role or phase.
            case unexpectedMessage = "unexpected_message"

            /// A response does not identify a pending request.
            case invalidCorrelation = "invalid_correlation"
        }
    }

    /// An explicit session-close message.
    public struct Close: Codable, Equatable, Sendable {
        /// The machine-readable reason for ending the session.
        public let reason: Reason

        /// Creates a close payload.
        ///
        /// - Parameter reason: The machine-readable close reason.
        public init(reason: Reason) {
            self.reason = reason
        }

        /// Reasons a peer can communicate before closing its transport.
        public enum Reason: String, Codable, Equatable, Sendable {
            /// The session completed normally.
            case normal

            /// A local owner cancelled the session.
            case cancelled

            /// The transport failed and cannot continue the session.
            case transportFailure = "transport_failure"

            /// A protocol invariant was violated.
            case protocolViolation = "protocol_violation"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case version
        case replyTo = "reply_to"
        case type
        case payload
    }

    private enum MessageType: String, Codable {
        case hello
        case welcome
        case ping
        case pong
        case protocolError = "protocol_error"
        case close
    }

    private struct EmptyPayload: Codable {}

    /// Encodes the stable, explicitly tagged wire representation.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(replyTo, forKey: .replyTo)

        switch body {
        case .hello(let hello):
            try container.encode(MessageType.hello, forKey: .type)
            try container.encode(hello, forKey: .payload)
        case .welcome(let welcome):
            try container.encode(MessageType.welcome, forKey: .type)
            try container.encode(welcome, forKey: .payload)
        case .ping:
            try container.encode(MessageType.ping, forKey: .type)
            try container.encode(EmptyPayload(), forKey: .payload)
        case .pong:
            try container.encode(MessageType.pong, forKey: .type)
            try container.encode(EmptyPayload(), forKey: .payload)
        case .protocolError(let error):
            try container.encode(MessageType.protocolError, forKey: .type)
            try container.encode(error, forKey: .payload)
        case .close(let close):
            try container.encode(MessageType.close, forKey: .type)
            try container.encode(close, forKey: .payload)
        }
    }

    /// Decodes the stable, explicitly tagged wire representation.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageID = try container.decode(UInt64.self, forKey: .messageID)
        version = try container.decode(UInt16.self, forKey: .version)
        replyTo = try container.decodeIfPresent(UInt64.self, forKey: .replyTo)

        switch try container.decode(MessageType.self, forKey: .type) {
        case .hello:
            body = .hello(try container.decode(Hello.self, forKey: .payload))
        case .welcome:
            body = .welcome(try container.decode(Welcome.self, forKey: .payload))
        case .ping:
            _ = try container.decode(EmptyPayload.self, forKey: .payload)
            body = .ping
        case .pong:
            _ = try container.decode(EmptyPayload.self, forKey: .payload)
            body = .pong
        case .protocolError:
            body = .protocolError(
                try container.decode(ProtocolError.self, forKey: .payload)
            )
        case .close:
            body = .close(try container.decode(Close.self, forKey: .payload))
        }
    }
}
