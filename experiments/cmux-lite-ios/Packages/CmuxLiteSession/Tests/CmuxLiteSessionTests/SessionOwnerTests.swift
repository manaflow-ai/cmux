internal import Foundation
import CmuxLiteProtocol
import CmuxLiteSession
import Testing

@Suite("Session owner")
struct SessionOwnerTests {
    @Test("client and deterministic fake host complete the handshake")
    func handshake() async throws {
        let codec = try FrameCodec()
        let (clientStream, hostStream) = await TestInMemoryByteStream.makePair(
            chunkSize: 2
        )
        let host = FakeMacHost(stream: hostStream, codec: codec)
        let client = CmuxLiteSession.SessionOwner(
            configuration: .client(
                hello: .init(clientName: "cmux-lite-ios", nonce: "client-nonce")
            ),
            stream: clientStream,
            codec: codec
        )
        var clientEvents = client.events.makeAsyncIterator()
        var hostEvents = host.owner.events.makeAsyncIterator()

        try await host.owner.start()
        try await client.start()

        #expect(await clientEvents.next() == .transportConnected)
        #expect(await hostEvents.next() == .transportConnected)
        #expect(await clientEvents.next() == .ready(sessionID: "session-1"))
        #expect(await hostEvents.next() == .ready(sessionID: "session-1"))
        #expect(await client.currentPhase() == .ready(sessionID: "session-1"))
        #expect(await host.owner.currentPhase() == .ready(sessionID: "session-1"))
    }

    @Test("a ping receives an automatic correlated pong")
    func pingPong() async throws {
        let codec = try FrameCodec()
        let (clientStream, hostStream) = await TestInMemoryByteStream.makePair()
        let host = FakeMacHost(stream: hostStream, codec: codec)
        let client = CmuxLiteSession.SessionOwner(
            configuration: .client(
                hello: .init(clientName: "cmux-lite-ios", nonce: "client-nonce")
            ),
            stream: clientStream,
            codec: codec
        )
        var clientEvents = client.events.makeAsyncIterator()

        try await host.owner.start()
        try await client.start()
        _ = await clientEvents.next()
        _ = await clientEvents.next()

        let pingID = try await client.sendPing()
        #expect(await clientEvents.next() == .pongReceived(replyTo: pingID))
    }

    @Test("explicit close reaches the peer and finishes both event streams")
    func close() async throws {
        let codec = try FrameCodec()
        let (clientStream, hostStream) = await TestInMemoryByteStream.makePair()
        let host = FakeMacHost(stream: hostStream, codec: codec)
        let client = CmuxLiteSession.SessionOwner(
            configuration: .client(
                hello: .init(clientName: "cmux-lite-ios", nonce: "client-nonce")
            ),
            stream: clientStream,
            codec: codec
        )
        var clientEvents = client.events.makeAsyncIterator()
        var hostEvents = host.owner.events.makeAsyncIterator()

        try await host.owner.start()
        try await client.start()
        _ = await clientEvents.next()
        _ = await hostEvents.next()
        _ = await clientEvents.next()
        _ = await hostEvents.next()

        await client.close(reason: .normal)

        #expect(await clientEvents.next() == .closed(.local(.normal)))
        #expect(await hostEvents.next() == .closed(.remote(.normal)))
        #expect(await clientEvents.next() == nil)
        #expect(await hostEvents.next() == nil)
    }

    @Test("a malformed incoming payload is surfaced and closes the owner")
    func malformedPayload() async throws {
        let codec = try FrameCodec()
        let (clientStream, hostStream) = await TestInMemoryByteStream.makePair()
        let host = FakeMacHost(stream: hostStream, codec: codec)
        var hostEvents = host.owner.events.makeAsyncIterator()
        try await host.owner.start()
        _ = await hostEvents.next()

        var malformed = Data([0, 0, 0, 1, 0x7B])
        try await clientStream.connect()
        try await clientStream.send(malformed)

        #expect(await hostEvents.next() == .failure(.framing(.malformedPayload)))
        #expect(await hostEvents.next() == .closed(.transportEnded))
        #expect(await hostEvents.next() == nil)
        malformed.removeAll(keepingCapacity: false)
    }

    @Test("commands report lifecycle failures without starting hidden work")
    func lifecycleFailures() async throws {
        let codec = try FrameCodec()
        let (clientStream, _) = await TestInMemoryByteStream.makePair()
        let client = CmuxLiteSession.SessionOwner(
            configuration: .client(
                hello: .init(clientName: "cmux-lite-ios", nonce: "client-nonce")
            ),
            stream: clientStream,
            codec: codec
        )

        await #expect(throws: CmuxLiteSession.SessionOwner.Failure.notStarted) {
            try await client.sendPing()
        }

        try await client.start()
        await #expect(throws: CmuxLiteSession.SessionOwner.Failure.notReady) {
            try await client.sendPing()
        }
        await #expect(
            throws: CmuxLiteSession.SessionOwner.Failure.alreadyStarted
        ) {
            try await client.start()
        }
        await client.close()
    }

    @Test("a valid but repeated message ID becomes an observable protocol failure")
    func repeatedMessageID() async throws {
        let codec = try FrameCodec()
        let (clientStream, hostStream) = await TestInMemoryByteStream.makePair()
        let host = FakeMacHost(stream: hostStream, codec: codec)
        let client = CmuxLiteSession.SessionOwner(
            configuration: .client(
                hello: .init(clientName: "cmux-lite-ios", nonce: "client-nonce")
            ),
            stream: clientStream,
            codec: codec
        )
        var clientEvents = client.events.makeAsyncIterator()
        var hostEvents = host.owner.events.makeAsyncIterator()

        try await host.owner.start()
        try await client.start()
        _ = await clientEvents.next()
        _ = await hostEvents.next()
        _ = await clientEvents.next()
        _ = await hostEvents.next()

        let duplicate = WireMessage(messageID: 1, body: .ping)
        try await clientStream.send(try codec.encode(duplicate))

        #expect(
            await hostEvents.next()
                == .failure(.protocolViolation(.invalidMessageID))
        )
        #expect(
            await hostEvents.next()
                == .closed(.protocolViolation(.invalidMessageID))
        )
        #expect(await hostEvents.next() == nil)
        await client.close()
    }
}

private actor TestInMemoryByteStream: ByteStream {
    enum Failure: Error {
        case closed
        case notConnected
    }

    private enum State {
        case idle
        case connected
        case closed
    }

    private let chunkSize: Int?
    private var state: State = .idle
    private var peer: TestInMemoryByteStream?
    private var inbound: [Data] = []
    private var peerEnded = false
    private var pendingReceive: CheckedContinuation<Data?, any Error>?

    init(chunkSize: Int? = nil) {
        self.chunkSize = chunkSize
    }

    static func makePair(
        chunkSize: Int? = nil
    ) async -> (TestInMemoryByteStream, TestInMemoryByteStream) {
        let first = TestInMemoryByteStream(chunkSize: chunkSize)
        let second = TestInMemoryByteStream(chunkSize: chunkSize)
        await first.setPeer(second)
        await second.setPeer(first)
        return (first, second)
    }

    func connect() async throws {
        switch state {
        case .idle:
            state = .connected
        case .connected:
            return
        case .closed:
            throw Failure.closed
        }
    }

    func send(_ bytes: Data) async throws {
        guard case .connected = state else {
            throw state == .closed ? Failure.closed : Failure.notConnected
        }
        guard !peerEnded else {
            throw Failure.closed
        }
        guard !bytes.isEmpty, let peer else {
            return
        }
        guard let chunkSize, chunkSize > 0 else {
            await peer.deliver(bytes)
            return
        }

        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            await peer.deliver(bytes.subdata(in: offset..<end))
            offset = end
        }
    }

    func receive() async throws -> Data? {
        guard case .connected = state else {
            if case .closed = state {
                return nil
            }
            throw Failure.notConnected
        }
        if !inbound.isEmpty {
            return inbound.removeFirst()
        }
        if peerEnded {
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingReceive = continuation
        }
    }

    func close() async {
        guard state != .closed else {
            return
        }
        state = .closed
        pendingReceive?.resume(returning: nil)
        pendingReceive = nil
        let peer = self.peer
        self.peer = nil
        await peer?.peerDidClose()
    }

    private func setPeer(_ peer: TestInMemoryByteStream) {
        self.peer = peer
    }

    private func deliver(_ bytes: Data) {
        guard state != .closed else {
            return
        }
        if let pendingReceive {
            self.pendingReceive = nil
            pendingReceive.resume(returning: bytes)
        } else {
            inbound.append(bytes)
        }
    }

    private func peerDidClose() {
        peerEnded = true
        pendingReceive?.resume(returning: nil)
        pendingReceive = nil
    }
}
