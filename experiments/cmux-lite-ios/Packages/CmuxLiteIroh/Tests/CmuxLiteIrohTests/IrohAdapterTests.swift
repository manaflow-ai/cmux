internal import Foundation
@testable import CmuxLiteIroh
import CmuxLiteProtocol
import CmuxLiteTransport
import IrohLib
import Testing

@Suite("Iroh byte-stream adapter")
struct IrohAdapterTests {
    @Test("the native provider shares one endpoint across concurrent callers")
    func providerSharesEndpoint() async throws {
        let endpoint = RecordingEndpointDriver()
        let factory = GatedEndpointFactory(endpoint: endpoint)
        let provider = IrohLibConnectionProvider(
            configuration: .standard,
            factory: factory
        )
        let route = try IrohRoute(
            endpointID: "peer-1",
            relayURL: "https://relay.example",
            directAddresses: ["192.0.2.1:7842"]
        )

        let first = Task { try await provider.connect(to: route) }
        await factory.waitUntilBindIsPending()
        let second = Task { try await provider.connect(to: route) }
        await factory.release()

        _ = try await first.value
        _ = try await second.value
        #expect(await factory.bindCount() == 1)
        #expect(await endpoint.routes() == [route, route])
        #expect(
            await endpoint.alpns() == [
                IrohLibConfiguration.standard.alpn,
                IrohLibConfiguration.standard.alpn,
            ]
        )

        await provider.close()
        #expect(await endpoint.isClosed())
        await #expect(throws: IrohOpenFailure.closed) {
            _ = try await provider.connect(to: route)
        }
    }

    @Test("native binding failures remain classified before fallback")
    func providerPreservesClassifiedFailure() async throws {
        let factory = FailingEndpointFactory(failure: .unauthorized)
        let provider = IrohLibConnectionProvider(
            configuration: .standard,
            factory: factory
        )
        let route = try IrohRoute(endpointID: "peer-1")

        await #expect(throws: IrohOpenFailure.unauthorized) {
            _ = try await provider.connect(to: route)
        }
        #expect(await factory.bindCount() == 1)
    }

    @Test("one endpoint publishes one route and owns one pending accept")
    func endpointOwnership() async throws {
        let endpoint = BlockingAcceptEndpointDriver()
        let factory = ImmediateEndpointFactory(endpoint: endpoint)
        let provider = IrohLibConnectionProvider(
            configuration: .standard,
            factory: factory
        )

        let firstRoute = try await provider.localRoute()
        let secondRoute = try await provider.localRoute()
        #expect(firstRoute == secondRoute)
        #expect(await factory.bindCount() == 1)

        let firstAccept = Task<IrohIncomingConnection?, any Error> {
            try await provider.accept()
        }
        await endpoint.waitUntilAcceptIsPending()
        await #expect(throws: IrohOpenFailure.acceptAlreadyPending) {
            _ = try await provider.accept()
        }

        await provider.close()
        _ = try? await firstAccept.value
        #expect(await endpoint.acceptCount() == 1)
        #expect(await endpoint.isClosed())
    }

    @Test("accept ownership is claimed while the endpoint is still binding")
    func acceptOwnershipDuringBind() async throws {
        let endpoint = BlockingAcceptEndpointDriver()
        let factory = GatedEndpointFactory(endpoint: endpoint)
        let provider = IrohLibConnectionProvider(
            configuration: .standard,
            factory: factory
        )

        let firstAccept = Task<IrohIncomingConnection?, any Error> {
            try await provider.accept()
        }
        await factory.waitUntilBindIsPending()
        await #expect(throws: IrohOpenFailure.acceptAlreadyPending) {
            _ = try await provider.accept()
        }

        await factory.release()
        await endpoint.waitUntilAcceptIsPending()
        await provider.close()
        _ = try? await firstAccept.value
        #expect(await factory.bindCount() == 1)
        #expect(await endpoint.acceptCount() == 1)
    }

    @Test("a rejected peer does not stop the endpoint host")
    func endpointHostIsolatesAdmissionRejection() async throws {
        let firstConnection = FakeIrohConnection()
        let secondConnection = WaitingIrohConnection()
        let firstPeer = try IrohRoute(endpointID: "denied-peer")
        let secondPeer = try IrohRoute(endpointID: "admitted-peer")
        let endpoint = QueueingEndpointProvider(
            localRoute: try IrohRoute(endpointID: "host-peer")
        )
        let host = IrohEndpointHost(
            endpoint: endpoint,
            codec: try FrameCodec()
        ) { peer in
            if peer.endpointID == firstPeer.endpointID {
                throw AdmissionFailure.denied
            }
            return .server(
                welcome: .init(
                    sessionID: "admitted-session",
                    nonce: "server-nonce"
                )
            )
        }

        try await host.start()
        await endpoint.enqueue(
            IrohIncomingConnection(
                peerRoute: firstPeer,
                connection: firstConnection
            )
        )
        await firstConnection.waitUntilClosed()
        #expect(await firstConnection.isClosed())
        #expect(await endpoint.acceptCount() >= 2)

        await endpoint.enqueue(
            IrohIncomingConnection(
                peerRoute: secondPeer,
                connection: secondConnection
            )
        )
        await endpoint.waitUntilAcceptCount(3)
        #expect(await host.activePeerEndpointIDs() == [secondPeer.endpointID])

        await host.close()
        #expect(await secondConnection.isClosed())
        #expect(await endpoint.isClosed())
    }

    @Test("the route catalog preserves public reachability hints")
    func routeCatalog() async throws {
        let route = try IrohRoute(
            endpointID: "peer-1",
            relayURL: "https://relay.example",
            directAddresses: ["192.0.2.1:7842"]
        )
        let catalog = IrohRouteCatalog()
        await catalog.publish(route)

        #expect(try await catalog.resolve(endpointID: "peer-1") == route)
        #expect(await catalog.snapshot() == [route])
        #expect(await catalog.remove(endpointID: "peer-1") == route)
        await #expect(throws: IrohRouteCatalog.Failure.unknownEndpoint("peer-1")) {
            _ = try await catalog.resolve(endpointID: "peer-1")
        }
    }

    @Test("a resolver cannot substitute a different endpoint identity")
    func routeResolverIdentityMismatch() async throws {
        let provider = FakeIrohProvider(
            behavior: .success(FakeIrohConnection())
        )
        let resolver = SubstitutingRouteResolver()
        let connector = IrohConnector(
            provider: provider,
            routeResolver: resolver
        )
        let route = try TransportRoute(
            kind: .iroh,
            identifier: "requested-peer"
        )

        await #expect(throws: TransportOpenFailure.invalidRoute) {
            _ = try await connector.open(route: route)
        }
        #expect(await provider.attemptCount() == 0)
    }

    @Test("configuration rejects unsafe native inputs")
    func configurationValidation() {
        #expect(
            throws: IrohLibConfiguration.Failure.emptyALPN
        ) {
            try IrohLibConfiguration(alpn: Data())
        }
        #expect(
            throws: IrohLibConfiguration.Failure.invalidSecretKeyLength(3)
        ) {
            try IrohLibConfiguration(
                alpn: Data("cmux-lite".utf8),
                secretKeyBytes: Data([1, 2, 3])
            )
        }
        #expect(
            throws: IrohLibConfiguration.Failure.invalidReceiveChunkLimit
        ) {
            try IrohLibConfiguration(
                alpn: Data("cmux-lite".utf8),
                maximumReceiveChunkBytes: 0
            )
        }
        #expect(
            throws: IrohLibConfiguration.Failure.emptyBindAddress
        ) {
            try IrohLibConfiguration(
                alpn: Data("cmux-lite".utf8),
                bindAddress: " \t"
            )
        }
        #expect(
            throws: IrohLibConfiguration.Failure.invalidCloseDrainTimeout
        ) {
            try IrohLibConfiguration(
                alpn: Data("cmux-lite".utf8),
                closeDrainTimeout: .zero
            )
        }
    }

    @Test("IrohLib error kinds map to explicit transport outcomes")
    func nativeFailureMapping() {
        #expect(
            IrohLibFailureMapper.openFailure(for: .invalidInput)
                == .invalidRoute
        )
        #expect(
            IrohLibFailureMapper.openFailure(for: .alpn)
                == .incompatiblePeer
        )
        #expect(
            IrohLibFailureMapper.openFailure(for: .closed)
                == .closed
        )
        #expect(
            IrohLibFailureMapper.openFailure(for: .timeout)
                == .unavailable
        )

        let allKinds: [IrohErrorKind] = [
            .invalidInput,
            .bind,
            .connect,
            .connection,
            .alpn,
            .keyParsing,
            .ticketParsing,
            .relay,
            .stream,
            .datagram,
            .callback,
            .closed,
            .timeout,
            .internal,
        ]
        #expect(allKinds.count == 14)
    }

    @Test("native route conversion validates identity before dialing")
    func nativeRouteConversion() throws {
        let route = try IrohRoute(
            endpointID: "523c7996bad77424e96786cf7a7205115337a5b4565cd25506a0f297b191a5ea",
            relayURL: "https://relay.example",
            directAddresses: ["192.0.2.1:7842"]
        )
        let address = try IrohLibRouteAddress.make(for: route)
        #expect(address.id().toBytes().count == 32)
        #expect(address.relayUrl() == route.relayURL)
        #expect(address.directAddresses() == route.directAddresses)

        let malformed = try IrohRoute(endpointID: "not-an-endpoint-id")
        #expect(throws: IrohOpenFailure.invalidRoute) {
            try IrohLibRouteAddress.make(for: malformed)
        }
    }

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

private actor GatedEndpointFactory: IrohEndpointFactory {
    private let endpoint: any IrohEndpointDriver
    private var continuation: CheckedContinuation<
        any IrohEndpointDriver,
        any Error
    >?
    private var observer: CheckedContinuation<Void, Never>?
    private var binds = 0

    init(endpoint: any IrohEndpointDriver) {
        self.endpoint = endpoint
    }

    func bind(
        configuration: IrohLibConfiguration
    ) async throws -> any IrohEndpointDriver {
        binds += 1
        observer?.resume()
        observer = nil
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBindIsPending() async {
        if continuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            observer = continuation
        }
    }

    func release() {
        continuation?.resume(returning: endpoint)
        continuation = nil
    }

    func bindCount() -> Int {
        binds
    }
}

private actor FailingEndpointFactory: IrohEndpointFactory {
    private let failure: IrohOpenFailure
    private var binds = 0

    init(failure: IrohOpenFailure) {
        self.failure = failure
    }

    func bind(
        configuration: IrohLibConfiguration
    ) async throws -> any IrohEndpointDriver {
        binds += 1
        throw failure
    }

    func bindCount() -> Int {
        binds
    }
}

private actor ImmediateEndpointFactory: IrohEndpointFactory {
    private let endpoint: any IrohEndpointDriver
    private var binds = 0

    init(endpoint: any IrohEndpointDriver) {
        self.endpoint = endpoint
    }

    func bind(
        configuration: IrohLibConfiguration
    ) async throws -> any IrohEndpointDriver {
        binds += 1
        return endpoint
    }

    func bindCount() -> Int {
        binds
    }
}

private actor RecordingEndpointDriver: IrohEndpointDriver {
    private var recordedRoutes: [IrohRoute] = []
    private var recordedALPNs: [Data] = []
    private var closed = false

    func localRoute() async throws -> IrohRoute {
        try IrohRoute(endpointID: "peer-1")
    }

    func connect(
        to route: IrohRoute,
        alpn: Data
    ) async throws -> any IrohConnection {
        guard !closed else {
            throw IrohOpenFailure.closed
        }
        recordedRoutes.append(route)
        recordedALPNs.append(alpn)
        return FakeIrohConnection()
    }

    func accept(alpn: Data) async throws -> IrohIncomingConnection? {
        nil
    }

    func close() async {
        closed = true
    }

    func routes() -> [IrohRoute] {
        recordedRoutes
    }

    func alpns() -> [Data] {
        recordedALPNs
    }

    func isClosed() -> Bool {
        closed
    }
}

private actor BlockingAcceptEndpointDriver: IrohEndpointDriver {
    private var accepts = 0
    private var pendingAccept: CheckedContinuation<
        IrohIncomingConnection?,
        any Error
    >?
    private var pendingObserver: CheckedContinuation<Void, Never>?
    private var closed = false

    func localRoute() async throws -> IrohRoute {
        try IrohRoute(endpointID: "blocking-accept-peer")
    }

    func connect(
        to route: IrohRoute,
        alpn: Data
    ) async throws -> any IrohConnection {
        guard !closed else {
            throw IrohOpenFailure.closed
        }
        return FakeIrohConnection()
    }

    func accept(alpn: Data) async throws -> IrohIncomingConnection? {
        accepts += 1
        pendingObserver?.resume()
        pendingObserver = nil
        return try await withCheckedThrowingContinuation { continuation in
            pendingAccept = continuation
        }
    }

    func close() async {
        guard !closed else {
            return
        }
        closed = true
        pendingAccept?.resume(returning: nil)
        pendingAccept = nil
    }

    func waitUntilAcceptIsPending() async {
        if pendingAccept != nil {
            return
        }
        await withCheckedContinuation { continuation in
            pendingObserver = continuation
        }
    }

    func acceptCount() -> Int {
        accepts
    }

    func isClosed() -> Bool {
        closed
    }
}

private enum FakeProviderBehavior: Sendable {
    case success(FakeIrohConnection)
    case failure(IrohOpenFailure)
}

private struct SubstitutingRouteResolver: IrohRouteResolver {
    func resolve(endpointID: String) async throws -> IrohRoute {
        try IrohRoute(endpointID: "different-peer")
    }
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
    private var closeObservers: [CheckedContinuation<Void, Never>] = []

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
        let observers = closeObservers
        closeObservers.removeAll(keepingCapacity: false)
        for observer in observers {
            observer.resume()
        }
    }

    func sentChunks() -> [Data] {
        sent
    }

    func isClosed() -> Bool {
        closed
    }

    func waitUntilClosed() async {
        if closed {
            return
        }
        await withCheckedContinuation { continuation in
            closeObservers.append(continuation)
        }
    }
}

private enum AdmissionFailure: Error {
    case denied
}

private actor WaitingIrohConnection: IrohConnection {
    private var receiveContinuation: CheckedContinuation<Data?, any Error>?
    private var closed = false

    func send(_ bytes: Data) async throws {
        guard !closed else {
            throw IrohOpenFailure.closed
        }
    }

    func receive() async throws -> Data? {
        guard !closed else {
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            receiveContinuation = continuation
        }
    }

    func close() async {
        guard !closed else {
            return
        }
        closed = true
        receiveContinuation?.resume(returning: nil)
        receiveContinuation = nil
    }

    func isClosed() -> Bool {
        closed
    }
}

private actor QueueingEndpointProvider: IrohEndpointProvider {
    private let route: IrohRoute
    private var queued: [IrohIncomingConnection] = []
    private var pendingAccept: CheckedContinuation<
        IrohIncomingConnection?,
        any Error
    >?
    private var accepts = 0
    private var acceptObservers: [(
        target: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private var closed = false

    init(localRoute: IrohRoute) {
        route = localRoute
    }

    func localRoute() async throws -> IrohRoute {
        guard !closed else {
            throw IrohOpenFailure.closed
        }
        return route
    }

    func connect(to route: IrohRoute) async throws -> any IrohConnection {
        throw IrohOpenFailure.unavailable
    }

    func accept() async throws -> IrohIncomingConnection? {
        accepts += 1
        resumeAcceptObservers()
        if !queued.isEmpty {
            return queued.removeFirst()
        }
        guard !closed else {
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingAccept = continuation
        }
    }

    func close() async {
        guard !closed else {
            return
        }
        closed = true
        pendingAccept?.resume(returning: nil)
        pendingAccept = nil
    }

    func enqueue(_ incoming: IrohIncomingConnection) {
        if let pendingAccept {
            self.pendingAccept = nil
            pendingAccept.resume(returning: incoming)
            return
        }
        queued.append(incoming)
    }

    func acceptCount() -> Int {
        accepts
    }

    func waitUntilAcceptCount(_ target: Int) async {
        if accepts >= target {
            return
        }
        await withCheckedContinuation { continuation in
            acceptObservers.append((target, continuation))
        }
    }

    func isClosed() -> Bool {
        closed
    }

    private func resumeAcceptObservers() {
        let ready = acceptObservers.filter { accepts >= $0.target }
        acceptObservers.removeAll { accepts >= $0.target }
        for observer in ready {
            observer.continuation.resume()
        }
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
