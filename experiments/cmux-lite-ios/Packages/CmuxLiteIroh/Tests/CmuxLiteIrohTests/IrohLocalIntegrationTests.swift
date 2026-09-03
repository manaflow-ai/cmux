internal import Foundation
import CmuxLiteIroh
import CmuxLiteProtocol
import CmuxLiteSession
import CmuxLiteTransport
import Testing

/// Exercises the generated binding through the same provider used by the app.
///
/// These tests deliberately use two real endpoints bound to ephemeral loopback
/// sockets. They do not involve the relay, a simulator, a renderer, or the
/// production app, so a failure points at the native transport boundary.
@Suite("Real Iroh loopback integration", .serialized)
struct IrohLocalIntegrationTests {
    @Test("two real endpoints exchange bytes over a direct loopback path")
    func directByteRoundTrip() async throws {
        try await withDirectProviders { server, client in
            let serverRoute = try await withProviderTimeout(
                "server bind",
                server: server,
                client: client
            ) {
                try await server.localRoute()
            }
            let clientRoute = try await withProviderTimeout(
                "client bind",
                server: server,
                client: client
            ) {
                try await client.localRoute()
            }

            #expect(!serverRoute.endpointID.isEmpty)
            #expect(!clientRoute.endpointID.isEmpty)
            #expect(serverRoute.endpointID != clientRoute.endpointID)
            #expect(!serverRoute.directAddresses.isEmpty)

            let acceptTask = Task<IrohIncomingConnection?, any Error> {
                try await server.accept()
            }
            let clientConnection: any IrohConnection = try await withProviderTimeout(
                "dial",
                server: server,
                client: client
            ) {
                try await client.connect(to: serverRoute)
            }

            // Opening a QUIC stream is lazy in Iroh. The first write is what
            // puts the stream on the wire, so it must happen concurrently with
            // the server's accept loop rather than after awaiting accept.
            let clientStream = IrohByteStream(connection: clientConnection)
            try await clientStream.connect()
            let payload = Data("cmux-lite direct transport".utf8)
            try await clientStream.send(payload)

            let incoming = try await withProviderTimeout(
                "accept",
                server: server,
                client: client
            ) {
                try await acceptTask.value
            }
            guard let incoming else {
                throw IntegrationFailure.missingIncomingConnection
            }
            #expect(incoming.peerRoute.endpointID == clientRoute.endpointID)

            let serverStream = IrohByteStream(connection: incoming.connection)
            try await serverStream.connect()
            #expect(
                try await withProviderTimeout(
                    "receive",
                    server: server,
                    client: client
                ) {
                    try await serverStream.receive()
                } == payload
            )

            await clientStream.close()
            await serverStream.close()
        }
    }

    @Test("real Iroh carries the cmux-lite handshake, ping, pong, and close")
    func sessionRoundTrip() async throws {
        try await withDirectProviders { server, client in
            let serverRoute = try await server.localRoute()
            let codec = try FrameCodec()
            let acceptTask = Task<IrohIncomingConnection?, any Error> {
                try await server.accept()
            }

            let clientConnection = try await withProviderTimeout(
                "session dial",
                server: server,
                client: client
            ) {
                try await client.connect(to: serverRoute)
            }
            let clientStream = IrohByteStream(connection: clientConnection)
            let clientOwner = SessionOwner(
                configuration: .client(
                    hello: .init(
                        clientName: "cmux-lite-ios",
                        nonce: "real-iroh-client"
                    )
                ),
                stream: clientStream,
                codec: codec
            )
            var clientEvents = clientOwner.events.makeAsyncIterator()

            try await clientOwner.start()
            #expect(await clientEvents.next() == .transportConnected)

            let incoming = try await withProviderTimeout(
                "session accept",
                server: server,
                client: client
            ) {
                try await acceptTask.value
            }
            guard let incoming else {
                throw IntegrationFailure.missingIncomingConnection
            }

            let serverOwner = SessionOwner(
                configuration: .server(
                    welcome: .init(
                        sessionID: "real-iroh-session",
                        nonce: "real-iroh-server"
                    )
                ),
                stream: IrohByteStream(connection: incoming.connection),
                codec: codec
            )
            var serverEvents = serverOwner.events.makeAsyncIterator()
            try await serverOwner.start()

            #expect(await serverEvents.next() == .transportConnected)
            #expect(
                await clientEvents.next()
                    == .ready(sessionID: "real-iroh-session")
            )
            #expect(
                await serverEvents.next()
                    == .ready(sessionID: "real-iroh-session")
            )

            let pingID = try await clientOwner.sendPing()
            #expect(
                await serverEvents.next() == .pingReceived(messageID: pingID)
            )
            #expect(
                await clientEvents.next() == .pongReceived(replyTo: pingID)
            )

            await clientOwner.close()
            #expect(
                await clientEvents.next() == .closed(.local(.normal))
            )
            #expect(
                await serverEvents.next() == .closed(.remote(.normal))
            )
            #expect(await clientEvents.next() == nil)
            #expect(await serverEvents.next() == nil)
        }
    }

    @Test("the endpoint host owns accept and session lifecycles")
    func endpointHostRoundTrip() async throws {
        try await withDirectProviders { server, client in
            let host = IrohEndpointHost(
                endpoint: server,
                codec: try FrameCodec()
            ) { _ in
                .server(
                    welcome: .init(
                        sessionID: "host-owned-session",
                        nonce: "host-owned-server"
                    )
                )
            }
            let hostEvents = AsyncEventIterator(host.events)
            try await host.start()

            guard case .listening(let serverRoute) = await hostEvents.next() else {
                throw IntegrationFailure.missingListeningEvent
            }
            let clientConnection = try await withProviderTimeout(
                "host dial",
                server: server,
                client: client
            ) {
                try await client.connect(to: serverRoute)
            }
            let clientOwner = SessionOwner(
                configuration: .client(
                    hello: .init(
                        clientName: "cmux-lite-ios",
                        nonce: "host-owned-client"
                    )
                ),
                stream: IrohByteStream(connection: clientConnection),
                codec: try FrameCodec()
            )
            var clientEvents = clientOwner.events.makeAsyncIterator()
            try await clientOwner.start()
            #expect(await clientEvents.next() == .transportConnected)

            let acceptedEvent = try await withIntegrationTimeout(
                "host accept event",
                operation: { await hostEvents.next() }
            )
            guard case .accepted(let peerRoute) = acceptedEvent else {
                throw IntegrationFailure.missingAcceptedEvent
            }
            #expect(
                peerRoute.endpointID
                    == (try await client.localRoute()).endpointID
            )
            #expect(
                await clientEvents.next()
                    == .ready(sessionID: "host-owned-session")
            )
            #expect(await host.activePeerEndpointIDs() == [peerRoute.endpointID])

            await clientOwner.close()
            #expect(
                await clientEvents.next() == .closed(.local(.normal))
            )
            #expect(
                try await withIntegrationTimeout(
                    "host session close event",
                    operation: { await hostEvents.next() }
                ) == .sessionClosed(peerEndpointID: peerRoute.endpointID)
            )
            #expect(await host.activePeerEndpointIDs().isEmpty)

            await host.close()
            #expect(await hostEvents.next() == .closed)
            #expect(await hostEvents.next() == nil)
        }
    }

    @Test("the transport dialer resolves a published Iroh route")
    func transportDialerRoundTrip() async throws {
        try await withDirectProviders { server, client in
            let serverRoute = try await server.localRoute()
            let catalog = IrohRouteCatalog()
            await catalog.publish(serverRoute)

            let genericRoute = try serverRoute.transportRoute()
            let dialer = try TransportDialer(
                routes: [genericRoute],
                policy: try TransportSelectionPolicy(
                    mode: .restricted(.iroh)
                ),
                connectors: [
                    .iroh: IrohConnector(
                        provider: client,
                        routeResolver: catalog
                    )
                ]
            )
            let acceptTask = Task<IrohIncomingConnection?, any Error> {
                try await server.accept()
            }

            let opened = try await withProviderTimeout(
                "dialer connect",
                server: server,
                client: client
            ) {
                try await dialer.connect()
            }
            guard let clientStream = opened as? IrohByteStream else {
                throw IntegrationFailure.wrongStreamType
            }
            try await clientStream.connect()
            let payload = Data("transport dialer route".utf8)
            try await clientStream.send(payload)

            let incoming = try await withProviderTimeout(
                "dialer accept",
                server: server,
                client: client
            ) {
                try await acceptTask.value
            }
            guard let incoming else {
                throw IntegrationFailure.missingIncomingConnection
            }
            let serverStream = IrohByteStream(connection: incoming.connection)
            try await serverStream.connect()
            #expect(await dialer.currentRoute() == genericRoute)
            let received = try await serverStream.receive()
            #expect(received == payload)
            await clientStream.close()
            await serverStream.close()
        }
    }

    @Test("one endpoint generation supports repeated sessions")
    func repeatedSessionsReuseEndpoint() async throws {
        try await withDirectProviders { server, client in
            let serverRoute = try await server.localRoute()
            let firstClientID = try await runSessionRound(
                server: server,
                client: client,
                serverRoute: serverRoute,
                sessionID: "repeated-session-1"
            )
            let secondClientID = try await runSessionRound(
                server: server,
                client: client,
                serverRoute: serverRoute,
                sessionID: "repeated-session-2"
            )

            #expect(firstClientID == secondClientID)
            #expect(try await server.localRoute() == serverRoute)
        }
    }

    @Test("closing a provider releases a pending native accept")
    func closeUnblocksAccept() async throws {
        let server = IrohLibConnectionProvider(
            configuration: try directConfiguration(seed: 0x31)
        )
        _ = try await server.localRoute()
        let acceptTask = Task<IrohIncomingConnection?, any Error> {
            try await server.accept()
        }

        await server.close()
        let accepted: IrohIncomingConnection?
        do {
            accepted = try await withIntegrationTimeout("close accept") {
                try await acceptTask.value
            }
        } catch IrohOpenFailure.closed {
            accepted = nil
        }
        #expect(accepted == nil)
        await #expect(throws: IrohOpenFailure.closed) {
            _ = try await server.localRoute()
        }
    }

    @Test("an incompatible ALPN is isolated and the listener remains usable")
    func incompatibleALPNDoesNotPoisonListener() async throws {
        let server = IrohLibConnectionProvider(
            configuration: try directConfiguration(
                seed: 0x41,
                alpn: Data("dev.cmux.cmux-lite/good".utf8)
            )
        )
        let wrongClient = IrohLibConnectionProvider(
            configuration: try directConfiguration(
                seed: 0x42,
                alpn: Data("dev.cmux.cmux-lite/wrong".utf8)
            )
        )
        let goodClient = IrohLibConnectionProvider(
            configuration: try directConfiguration(
                seed: 0x43,
                alpn: Data("dev.cmux.cmux-lite/good".utf8)
            )
        )

        do {
            let serverRoute = try await server.localRoute()
            let acceptTask = Task<IrohIncomingConnection?, any Error> {
                try await server.accept()
            }

            var rejected = false
            do {
                _ = try await withIntegrationTimeout(
                    "incompatible dial",
                    onTimeout: { await wrongClient.close() }
                ) {
                    try await wrongClient.connect(to: serverRoute)
                }
            } catch {
                rejected = error is IrohOpenFailure
            }
            #expect(rejected)

            let goodConnection = try await withProviderTimeout(
                "compatible dial after rejection",
                server: server,
                client: goodClient
            ) {
                try await goodClient.connect(to: serverRoute)
            }
            let goodStream = IrohByteStream(connection: goodConnection)
            try await goodStream.connect()
            try await goodStream.send(Data("after rejection".utf8))

            let incoming = try await withProviderTimeout(
                "compatible accept after rejection",
                server: server,
                client: goodClient
            ) {
                try await acceptTask.value
            }
            guard let incoming else {
                throw IntegrationFailure.missingIncomingConnection
            }
            let serverStream = IrohByteStream(connection: incoming.connection)
            try await serverStream.connect()
            #expect(try await serverStream.receive() == Data("after rejection".utf8))
            await goodStream.close()
            await serverStream.close()
            await goodClient.close()
            await wrongClient.close()
            await server.close()
        } catch {
            await goodClient.close()
            await wrongClient.close()
            await server.close()
            throw error
        }
    }
}

private enum IntegrationFailure: Error, CustomStringConvertible, Sendable {
    case timedOut(String)
    case missingIncomingConnection
    case wrongStreamType
    case missingListeningEvent
    case missingAcceptedEvent

    var description: String {
        switch self {
        case .timedOut(let operation):
            return "Iroh integration operation timed out: \(operation)"
        case .missingIncomingConnection:
            return "Iroh endpoint closed before accepting a connection"
        case .wrongStreamType:
            return "Iroh connector returned an unexpected byte-stream type"
        case .missingListeningEvent:
            return "Iroh endpoint host did not publish a listening route"
        case .missingAcceptedEvent:
            return "Iroh endpoint host did not publish an accepted peer"
        }
    }
}

private final class AsyncEventIterator<Element: Sendable>: @unchecked Sendable {
    private var iterator: AsyncStream<Element>.Iterator
    private let lock = NSLock()

    init(_ stream: AsyncStream<Element>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> Element? {
        var localIterator = lock.withLock { iterator }
        let element = await localIterator.next()
        lock.withLock {
            iterator = localIterator
        }
        return element
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private func withIntegrationTimeout<T: Sendable>(
    _ operationName: String,
    onTimeout: @escaping @Sendable () async -> Void = {},
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await ContinuousClock().sleep(for: .seconds(10))
            await onTimeout()
            throw IntegrationFailure.timedOut(operationName)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

private func withProviderTimeout<T: Sendable>(
    _ operationName: String,
    server: IrohLibConnectionProvider,
    client: IrohLibConnectionProvider,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withIntegrationTimeout(
        operationName,
        onTimeout: {
            await client.close()
            await server.close()
        },
        operation: operation
    )
}

private func directConfiguration(
    seed: UInt8,
    alpn: Data = Data("dev.cmux.cmux-lite/integration/1".utf8)
) throws -> IrohLibConfiguration {
    let key = Data((0..<32).map { offset in
        seed &+ UInt8(offset)
    })
    return try IrohLibConfiguration(
        alpn: alpn,
        relayMode: .disabled,
        secretKeyBytes: key,
        maximumReceiveChunkBytes: 64 * 1024,
        bindAddress: "127.0.0.1:0"
    )
}

private func withDirectProviders<T: Sendable>(
    _ operation: @Sendable (
        IrohLibConnectionProvider,
        IrohLibConnectionProvider
    ) async throws -> T
) async throws -> T {
    let server = IrohLibConnectionProvider(
        configuration: try directConfiguration(seed: 0x11)
    )
    let client = IrohLibConnectionProvider(
        configuration: try directConfiguration(seed: 0x22)
    )

    do {
        let value = try await operation(server, client)
        await client.close()
        await server.close()
        return value
    } catch {
        await client.close()
        await server.close()
        throw error
    }
}

private func runSessionRound(
    server: IrohLibConnectionProvider,
    client: IrohLibConnectionProvider,
    serverRoute: IrohRoute,
    sessionID: String
) async throws -> String {
    let codec = try FrameCodec()
    let acceptTask = Task<IrohIncomingConnection?, any Error> {
        try await server.accept()
    }
    let clientConnection = try await withProviderTimeout(
        "repeated session dial",
        server: server,
        client: client
    ) {
        try await client.connect(to: serverRoute)
    }

    let clientOwner = SessionOwner(
        configuration: .client(
            hello: .init(
                clientName: "cmux-lite-ios",
                nonce: "repeated-\(sessionID)"
            )
        ),
        stream: IrohByteStream(connection: clientConnection),
        codec: codec
    )
    var clientEvents = clientOwner.events.makeAsyncIterator()
    try await clientOwner.start()
    _ = await clientEvents.next()

    let incoming = try await withProviderTimeout(
        "repeated session accept",
        server: server,
        client: client
    ) {
        try await acceptTask.value
    }
    guard let incoming else {
        throw IntegrationFailure.missingIncomingConnection
    }

    let serverOwner = SessionOwner(
        configuration: .server(
            welcome: .init(
                sessionID: sessionID,
                nonce: "repeated-\(sessionID)-server"
            )
        ),
        stream: IrohByteStream(connection: incoming.connection),
        codec: codec
    )
    var serverEvents = serverOwner.events.makeAsyncIterator()
    try await serverOwner.start()
    _ = await serverEvents.next()
    _ = await clientEvents.next()
    _ = await serverEvents.next()

    let pingID = try await clientOwner.sendPing()
    #expect(await serverEvents.next() == .pingReceived(messageID: pingID))
    #expect(await clientEvents.next() == .pongReceived(replyTo: pingID))
    await clientOwner.close()
    _ = await clientEvents.next()
    _ = await serverEvents.next()
    return try await client.localRoute().endpointID
}
