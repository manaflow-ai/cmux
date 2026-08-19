import Testing
import CmuxLiteProtocol

@Suite("Session state machine")
struct SessionStateMachineTests {
    @Test("client and server complete the same correlated handshake")
    func handshake() throws {
        let pair = try Self.makeReadyPair()

        #expect(pair.client.phase == .ready(sessionID: "session-1"))
        #expect(pair.server.phase == .ready(sessionID: "session-1"))
    }

    @Test("both peers can pipeline correlated pings once ready")
    func correlatedPingPong() throws {
        var pair = try Self.makeReadyPair()

        let clientPing = WireMessage(messageID: 2, body: .ping)
        let serverPing = WireMessage(messageID: 2, body: .ping)
        try pair.client.recordSent(clientPing)
        try pair.server.recordReceived(clientPing)
        try pair.server.recordSent(serverPing)
        try pair.client.recordReceived(serverPing)

        let serverPong = WireMessage(messageID: 3, replyTo: 2, body: .pong)
        let clientPong = WireMessage(messageID: 3, replyTo: 2, body: .pong)
        try pair.server.recordSent(serverPong)
        try pair.client.recordReceived(serverPong)
        try pair.client.recordSent(clientPong)
        try pair.server.recordReceived(clientPong)

        #expect(pair.client.phase == .ready(sessionID: "session-1"))
        #expect(pair.server.phase == .ready(sessionID: "session-1"))
    }

    @Test("unsupported protocol versions fail closed")
    func unsupportedVersion() throws {
        var client = try Self.makeHandshaking(role: .client)
        let hello = WireMessage(
            messageID: 1,
            version: WireMessage.currentVersion + 1,
            body: .hello(.init(clientName: "cmux-lite-ios", nonce: "nonce"))
        )

        #expect(throws: SessionStateMachine.Violation.unsupportedVersion) {
            try client.recordSent(hello)
        }
        #expect(
            client.phase == .closed(.protocolViolation(.unsupportedVersion))
        )
    }

    @Test("zero, repeated, and decreasing sender message IDs fail closed")
    func messageIDsMustIncrease() throws {
        var zero = try Self.makeHandshaking(role: .client)
        #expect(throws: SessionStateMachine.Violation.invalidMessageID) {
            try zero.recordSent(
                WireMessage(
                    messageID: 0,
                    body: .hello(.init(clientName: "client", nonce: "nonce"))
                )
            )
        }

        var pair = try Self.makeReadyPair()
        try pair.client.recordSent(WireMessage(messageID: 4, body: .ping))
        #expect(throws: SessionStateMachine.Violation.invalidMessageID) {
            try pair.client.recordSent(WireMessage(messageID: 4, body: .ping))
        }
        #expect(
            pair.client.phase == .closed(.protocolViolation(.invalidMessageID))
        )
    }

    @Test("message direction and phase are enforced")
    func unexpectedMessageDirection() throws {
        var client = try Self.makeHandshaking(role: .client)
        let welcome = WireMessage(
            messageID: 1,
            replyTo: 1,
            body: .welcome(.init(sessionID: "session", nonce: "server"))
        )

        #expect(throws: SessionStateMachine.Violation.unexpectedMessage) {
            try client.recordSent(welcome)
        }
        #expect(
            client.phase == .closed(.protocolViolation(.unexpectedMessage))
        )
    }

    @Test("welcome must correlate to the exact hello")
    func welcomeCorrelation() throws {
        var client = try Self.makeHandshaking(role: .client)
        try client.recordSent(
            WireMessage(
                messageID: 1,
                body: .hello(.init(clientName: "client", nonce: "nonce"))
            )
        )

        #expect(throws: SessionStateMachine.Violation.invalidCorrelation) {
            try client.recordReceived(
                WireMessage(
                    messageID: 1,
                    replyTo: 99,
                    body: .welcome(
                        .init(sessionID: "session", nonce: "server-nonce")
                    )
                )
            )
        }
        #expect(
            client.phase == .closed(.protocolViolation(.invalidCorrelation))
        )
    }

    @Test("hello cannot claim to be a response")
    func helloCannotReply() throws {
        var client = try Self.makeHandshaking(role: .client)

        #expect(throws: SessionStateMachine.Violation.invalidCorrelation) {
            try client.recordSent(
                WireMessage(
                    messageID: 1,
                    replyTo: 99,
                    body: .hello(.init(clientName: "client", nonce: "nonce"))
                )
            )
        }
        #expect(
            client.phase == .closed(.protocolViolation(.invalidCorrelation))
        )
    }

    @Test("pong consumes one pending correlation")
    func pongCannotBeReplayed() throws {
        var pair = try Self.makeReadyPair()
        let ping = WireMessage(messageID: 2, body: .ping)
        try pair.client.recordSent(ping)
        try pair.server.recordReceived(ping)

        let firstPong = WireMessage(messageID: 2, replyTo: 2, body: .pong)
        try pair.server.recordSent(firstPong)
        try pair.client.recordReceived(firstPong)

        #expect(throws: SessionStateMachine.Violation.invalidCorrelation) {
            try pair.client.recordReceived(
                WireMessage(messageID: 3, replyTo: 2, body: .pong)
            )
        }
        #expect(
            pair.client.phase == .closed(.protocolViolation(.invalidCorrelation))
        )
    }

    @Test("empty or oversized handshake metadata is rejected")
    func handshakeMetadataBounds() throws {
        var empty = try Self.makeHandshaking(role: .client)
        #expect(throws: SessionStateMachine.Violation.invalidHandshakeMetadata) {
            try empty.recordSent(
                WireMessage(
                    messageID: 1,
                    body: .hello(.init(clientName: "", nonce: "nonce"))
                )
            )
        }

        var oversized = try Self.makeHandshaking(role: .client)
        #expect(throws: SessionStateMachine.Violation.invalidHandshakeMetadata) {
            try oversized.recordSent(
                WireMessage(
                    messageID: 1,
                    body: .hello(
                        .init(clientName: String(repeating: "a", count: 65), nonce: "n")
                    )
                )
            )
        }
    }

    @Test("explicit close reason survives later transport teardown")
    func explicitCloseWins() throws {
        var pair = try Self.makeReadyPair()
        try pair.client.recordSent(
            WireMessage(
                messageID: 2,
                body: .close(.init(reason: .normal))
            )
        )

        pair.client.transportDidClose()
        pair.client.transportDidClose()

        #expect(pair.client.phase == .closed(.local(.normal)))
    }

    @Test("transport teardown is idempotent in every nonterminal phase")
    func transportTeardown() throws {
        var idle = SessionStateMachine(role: .client)
        idle.transportDidClose()
        idle.transportDidClose()
        #expect(idle.phase == .closed(.transportEnded))

        var connecting = SessionStateMachine(role: .client)
        try connecting.beginConnecting()
        connecting.transportDidClose()
        connecting.transportDidClose()
        #expect(connecting.phase == .closed(.transportEnded))
    }

    private static func makeHandshaking(
        role: SessionStateMachine.Role
    ) throws -> SessionStateMachine {
        var state = SessionStateMachine(role: role)
        try state.beginConnecting()
        try state.transportDidConnect()
        return state
    }

    private static func makeReadyPair() throws -> (
        client: SessionStateMachine,
        server: SessionStateMachine
    ) {
        var client = try makeHandshaking(role: .client)
        var server = try makeHandshaking(role: .server)
        let hello = WireMessage(
            messageID: 1,
            body: .hello(.init(clientName: "cmux-lite-ios", nonce: "client-nonce"))
        )
        let welcome = WireMessage(
            messageID: 1,
            replyTo: 1,
            body: .welcome(
                .init(sessionID: "session-1", nonce: "server-nonce")
            )
        )

        try client.recordSent(hello)
        try server.recordReceived(hello)
        try server.recordSent(welcome)
        try client.recordReceived(welcome)
        return (client, server)
    }
}
