internal import Foundation
import CmuxLiteIroh
import CmuxLiteProtocol
import CmuxLiteTransport
import Testing

@Suite("Iroh byte-stream adapter")
struct IrohAdapterTests {
    @Test("the adapter delegates lifecycle and bytes to the native connection")
    func lifecycleAndBytes() async throws {
        let connection = FakeIrohConnection(inbound: [Data("reply".utf8)])
        let provider = FakeIrohProvider(behavior: .success(connection))
        let connector = IrohConnector(provider: provider)
        let route = try TransportRoute(kind: .iroh, identifier: "peer-1")
        let opened = try await connector.open(route: route)
        let stream = try #require(opened as? IrohByteStream)

        await #expect(
            throws: IrohByteStream.Failure.notConnected
        ) {
            try await stream.send(Data("before".utf8))
        }

        try await stream.connect()
        try await stream.connect()
        try await stream.send(Data("request".utf8))

        #expect(await connection.sentChunks() == [Data("request".utf8)])
        #expect(try await stream.receive() == Data("reply".utf8))
        #expect(await stream.currentState() == .connected)

        await stream.close()
        await stream.close()
        #expect(await stream.currentState() == .closed)
        #expect(await connection.isClosed())
        #expect(try await stream.receive() == nil)
        await #expect(throws: IrohByteStream.Failure.closed) {
            try await stream.send(Data("after".utf8))
        }
    }

    @Test("binding failures map to transport fallback classifications")
    func failureMapping() async throws {
        let route = try TransportRoute(kind: .iroh, identifier: "peer-1")
        let provider = FakeIrohProvider(behavior: .failure(.unavailable))
        let connector = IrohConnector(provider: provider)

        await #expect(throws: TransportOpenFailure.unavailable) {
            try await connector.open(route: route)
        }

        let unauthorizedProvider = FakeIrohProvider(
            behavior: .failure(.unauthorized)
        )
        let unauthorizedConnector = IrohConnector(
            provider: unauthorizedProvider
        )
        await #expect(throws: TransportOpenFailure.unauthorized) {
            try await unauthorizedConnector.open(route: route)
        }
    }

    @Test("non-Iroh routes are rejected before the provider is called")
    func routeKindValidation() async throws {
        let provider = FakeIrohProvider(behavior: .success(FakeIrohConnection()))
        let connector = IrohConnector(provider: provider)
        let route = try TransportRoute(kind: .tailscale, identifier: "ts-1")

        await #expect(throws: TransportOpenFailure.invalidRoute) {
            try await connector.open(route: route)
        }
        #expect(await provider.attemptCount() == 0)
    }

    @Test("a denied Iroh route stops the generic dialer's fallback")
    func dialerPreservesDenial() async throws {
        let irohRoute = try TransportRoute(kind: .iroh, identifier: "peer-1")
        let tailscaleRoute = try TransportRoute(
            kind: .tailscale,
            identifier: "ts-1"
        )
        let provider = FakeIrohProvider(behavior: .failure(.unauthorized))
        let connector = IrohConnector(provider: provider)
        let tailscale = SucceedingConnector()
        let dialer = try TransportDialer(
            routes: [irohRoute, tailscaleRoute],
            policy: try TransportSelectionPolicy(),
            connectors: [.iroh: connector, .tailscale: tailscale]
        )

        await #expect(
            throws: TransportDialer.Failure.nonRetryable(
                irohRoute,
                reason: .unauthorized
            )
        ) {
            try await dialer.connect()
        }
        #expect(await tailscale.attemptCount() == 0)
    }

    @Test("overlapping native sends are rejected without interleaving")
    func overlappingSends() async throws {
        let connection = BlockingIrohConnection()
        let stream = IrohByteStream(connection: connection)
        try await stream.connect()

        let first = Task {
            try await stream.send(Data("first".utf8))
        }
        await connection.waitUntilSendIsPending()

        await #expect(throws: IrohByteStream.Failure.sendAlreadyPending) {
            try await stream.send(Data("second".utf8))
        }
        await connection.releaseSend()
        try await first.value
        #expect(await connection.sentChunks() == [Data("first".utf8)])
    }

    @Test("an empty native receive is rejected instead of leaking a fake chunk")
    func emptyReceiveFailsClosed() async throws {
        let connection = FakeIrohConnection(inbound: [Data()])
        let stream = IrohByteStream(connection: connection)
        try await stream.connect()

        await #expect(throws: IrohByteStream.Failure.emptyReceivedChunk) {
            try await stream.receive()
        }
    }

    @Test("explicit close waits for native teardown before returning")
    func closeIsOrdered() async throws {
        let connection = BlockingCloseIrohConnection()
        let stream = IrohByteStream(connection: connection)
        try await stream.connect()

        let closeTask = Task {
            await stream.close()
        }
        await connection.waitUntilCloseIsPending()
        #expect(await connection.isClosed() == false)

        await connection.releaseClose()
        await closeTask.value
        #expect(await connection.isClosed())
    }
}

private enum FakeProviderBehavior: Sendable {
    case success(FakeIrohConnection)
    case failure(IrohOpenFailure)
}

private actor FakeIrohProvider: IrohConnectionProvider {
    private let behavior: FakeProviderBehavior
    private var attempts = 0

    init(behavior: FakeProviderBehavior) {
        self.behavior = behavior
    }

    func connect(to route: IrohRoute) async throws -> any IrohConnection {
        attempts += 1
        switch behavior {
        case .success(let connection):
            return connection
        case .failure(let failure):
            throw failure
        }
    }

    func attemptCount() -> Int {
        attempts
    }
}

private actor FakeIrohConnection: IrohConnection {
    private var inbound: [Data]
    private var sent: [Data] = []
    private var closed = false

    init(inbound: [Data] = []) {
        self.inbound = inbound
    }

    func send(_ bytes: Data) async throws {
        guard !closed else {
            throw IrohOpenFailure.closed
        }
        sent.append(bytes)
    }

    func receive() async throws -> Data? {
        guard !closed else {
            return nil
        }
        guard !inbound.isEmpty else {
            return nil
        }
        return inbound.removeFirst()
    }

    func close() async {
        closed = true
    }

    func sentChunks() -> [Data] {
        sent
    }

    func isClosed() -> Bool {
        closed
    }
}

private actor SucceedingConnector: TransportConnector {
    private var attempts = 0

    func open(route: TransportRoute) async throws -> any ByteStream {
        attempts += 1
        return FakeByteStream()
    }

    func attemptCount() -> Int {
        attempts
    }
}

private actor FakeByteStream: ByteStream {
    func connect() async throws {}

    func send(_ bytes: Data) async throws {}

    func receive() async throws -> Data? {
        nil
    }

    func close() async {}
}

private actor BlockingIrohConnection: IrohConnection {
    private var sent: [Data] = []
    private var pendingSend: CheckedContinuation<Void, any Error>?
    private var pendingObserver: CheckedContinuation<Void, Never>?

    func send(_ bytes: Data) async throws {
        pendingObserver?.resume()
        pendingObserver = nil
        try await withCheckedThrowingContinuation { continuation in
            pendingSend = continuation
        }
        sent.append(bytes)
    }

    func receive() async throws -> Data? {
        nil
    }

    func close() async {
        pendingSend?.resume(returning: ())
        pendingSend = nil
    }

    func waitUntilSendIsPending() async {
        if pendingSend != nil {
            return
        }
        await withCheckedContinuation { continuation in
            pendingObserver = continuation
        }
    }

    func releaseSend() {
        pendingSend?.resume(returning: ())
        pendingSend = nil
    }

    func sentChunks() -> [Data] {
        sent
    }
}

private actor BlockingCloseIrohConnection: IrohConnection {
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private var closeObserver: CheckedContinuation<Void, Never>?
    private var closed = false

    func send(_ bytes: Data) async throws {}

    func receive() async throws -> Data? {
        nil
    }

    func close() async {
        closeObserver?.resume()
        closeObserver = nil
        await withCheckedContinuation { continuation in
            closeContinuation = continuation
        }
        closed = true
    }

    func waitUntilCloseIsPending() async {
        if closeContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            closeObserver = continuation
        }
    }

    func releaseClose() {
        closeContinuation?.resume()
        closeContinuation = nil
    }

    func isClosed() -> Bool {
        closed
    }
}
