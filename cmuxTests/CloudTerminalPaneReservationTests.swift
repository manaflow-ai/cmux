import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Optimistic Cloud pane creation: the pane exists before the terminal, input
/// typed meanwhile reaches the terminal, and one request id owns retry and cancel.
@Suite("Cloud terminal pane reservation")
struct CloudTerminalPaneReservationTests {
    @Test
    func relayQueuesInputUntilARouterIsAttachedThenForwardsInOrder() async throws {
        let relay = CloudOptimisticInputRelay()
        relay.send(.bytes(Data("ls".utf8)))
        relay.send(.namedKey("enter"))
        #expect(relay.pendingCount == 2)

        let queue = DispatchQueue(label: "reservation-test")
        let router = CloudTuiManualIOInputRouter(surfaceID: 17, queue: queue)
        let connection = try CloudManualMirrorSocketFixture()
        defer { connection.close() }
        // Attaching flushes the queue into the router (which itself holds the
        // lines until a transport exists) and forwards later input directly.
        relay.attach(router)
        #expect(relay.pendingCount == 0)
        relay.send(.bytes(Data("pwd\n".utf8)))
        #expect(relay.pendingCount == 0)

        let transport = CloudTuiManualIOConnection(socketPath: connection.socketPath)
        defer { transport.close() }
        try await transport.start()
        router.setConnection(transport)
        let first = await connection.nextCommand(timeout: .seconds(2))
        let second = await connection.nextCommand(timeout: .seconds(2))
        let third = await connection.nextCommand(timeout: .seconds(2))
        #expect(first?.inputBytes == Data("ls".utf8))
        #expect(second?.cmd == "send-key")
        #expect(third?.inputBytes == Data("pwd\n".utf8))
        #expect(first?.surface == 17 && second?.surface == 17 && third?.surface == 17)
    }

    @Test
    func relaySendsEarlyInputToStableTerminalBeforePromotingTheSurfaceRouter() async throws {
        let relay = CloudOptimisticInputRelay()
        let sender = RecordingUntrackedSender()
        relay.send(.bytes(Data("ls".utf8)))
        relay.send(.namedKey("enter"))
        relay.bindRemoteTerminal(terminalID: "term_created", sender: sender)

        let queue = DispatchQueue(label: "reservation-early-input-test")
        let router = CloudTuiManualIOInputRouter(surfaceID: 17, queue: queue)
        let connection = try CloudManualMirrorSocketFixture()
        defer { connection.close() }
        relay.attach(router)

        try await Self.waitUntil { relay.pendingCount == 0 }
        let requests = await sender.requests
        #expect(requests.map(\.operation) == ["terminal.input.write", "terminal.input.keys"])
        #expect(requests[0].params["terminal"] as? String == "term_created")
        #expect(requests[1].params["terminal"] as? String == "term_created")
        #expect((requests[1].params["keys"] as? [String]) == ["enter"])

        let transport = CloudTuiManualIOConnection(socketPath: connection.socketPath)
        defer { transport.close() }
        try await transport.start()
        router.setConnection(transport)
        relay.send(.bytes(Data("pwd\n".utf8)))
        let forwarded = await connection.nextCommand(timeout: .seconds(2))
        #expect(forwarded?.inputBytes == Data("pwd\n".utf8))
        #expect(forwarded?.surface == 17)
    }

    @Test
    func relayDiscardDropsQueuedInputAndALaterAttachResumesForwarding() {
        let relay = CloudOptimisticInputRelay()
        relay.send(.bytes(Data("typed too early".utf8)))
        relay.discard()
        #expect(relay.pendingCount == 0)
        relay.send(.bytes(Data("still discarded".utf8)))
        #expect(relay.pendingCount == 0)
        let router = CloudTuiManualIOInputRouter(surfaceID: 17)
        relay.attach(router)
        relay.send(.bytes(Data("after retry".utf8)))
        #expect(relay.pendingCount == 0)
    }

    @Test
    func relayBoundsTheQueue() {
        let relay = CloudOptimisticInputRelay()
        for _ in 0..<5_000 { relay.send(.bytes(Data([0x61]))) }
        #expect(relay.pendingCount == 4_096)
    }

    @Test @MainActor
    func storeRoutesFailureToTheReservedPaneAndReplaysTheSameRequestOnRetry() async throws {
        let store = CloudPaneCreationFailureStore()
        let requestID = store.beginRequest()
        let resource = Self.resource()
        let completions = AsyncStream<Void>.makeStream()
        var completion = completions.stream.makeAsyncIterator()
        var creates = 0
        var projections = 0
        var inlineFailures = 0
        var starts = 0
        store.run(
            machine: resource.machine,
            requestID: requestID,
            create: { creates += 1; return resource },
            project: { resource in
                projections += 1
                if projections == 1 { throw CloudDiagnosticFailure.network }
                return (SurfaceProjection(resource: resource.id, workspaceID: UUID(), panelID: UUID()), false)
            },
            onStart: { starts += 1 },
            onFinish: { completions.continuation.yield(()) },
            inlineFailure: { _ in inlineFailures += 1 },
            discardProjection: { _ in }
        )
        _ = await completion.next()
        // The failure lives in the pane, never on the workspace card.
        #expect(inlineFailures == 1)
        #expect(store.failure == nil)
        #expect(store.hasActiveRequests)

        store.retry(requestID: requestID)
        _ = await completion.next()
        #expect(creates == 1)
        #expect(projections == 2)
        #expect(starts == 2)
        #expect(!store.hasActiveRequests)
    }

    @Test @MainActor
    func closingTheReservedPaneCancelsOnlyItsRequest() async throws {
        let store = CloudPaneCreationFailureStore()
        let resource = Self.resource()
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        var finishes = 0
        var projections = 0
        let cancelledID = store.beginRequest()
        store.run(
            machine: resource.machine,
            requestID: cancelledID,
            create: {
                started.resolve(true)
                _ = await release.result
                return resource
            },
            project: { resource in
                projections += 1
                return (SurfaceProjection(resource: resource.id, workspaceID: UUID(), panelID: UUID()), false)
            },
            onStart: {},
            onFinish: { finishes += 1 },
            inlineFailure: { _ in },
            discardProjection: { _ in }
        )
        let survivingID = store.beginRequest()
        let survivingDone = CloudLinkFirstValue<Bool>()
        store.run(
            machine: resource.machine,
            requestID: survivingID,
            create: { resource },
            project: { resource in
                (SurfaceProjection(resource: resource.id, workspaceID: UUID(), panelID: UUID()), false)
            },
            onStart: {},
            onFinish: { survivingDone.resolve(true) },
            inlineFailure: { _ in },
            discardProjection: { _ in }
        )
        _ = await started.result
        store.cancel(requestID: cancelledID)
        release.resolve(true)
        _ = await survivingDone.result
        try await Self.waitUntil { finishes == 1 }
        #expect(projections == 0)
        #expect(store.failure == nil)
        #expect(!store.hasActiveRequests)
    }

    private static func resource() -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: .cloud("reservation-fixture"), kind: .terminal, key: "term_created"),
            title: "", detail: nil, lifecycle: .launching, agent: nil,
            remoteWorkspace: nil, remoteViews: [], port: nil, url: nil
        )
    }

    @MainActor
    private static func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}

private actor RecordingUntrackedSender: CloudTuiUntrackedCommandSending {
    private(set) var requests: [CloudTuiRequest] = []

    func sendUntrackedTuiCommand(arguments: CloudTuiRequest) async throws {
        requests.append(arguments)
    }
}
