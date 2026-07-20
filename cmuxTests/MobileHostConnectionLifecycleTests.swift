import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileRPC
import Foundation
@preconcurrency import Network
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension MobileHostAuthorizationTests {
    @Test func testMobileHostConnectionRunOwnsTransportUntilRemoteClose() async {
        let connectionID = UUID()
        let transport = GatedMobileHostByteTransport()
        let closeRecorder = MobileHostConnectionCloseRecorder()
        let session = MobileHostConnection(
            id: connectionID,
            transport: transport,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { id in
                await closeRecorder.record(id)
            }
        )

        let runTask = Task {
            await session.run()
        }
        await transport.waitUntilReceiveStarted()
        #expect(await closeRecorder.recordedIDs().isEmpty)

        await transport.finishReceiving()
        await runTask.value
        await session.close(reason: "duplicate close after remote EOF")

        #expect(await transport.observedConnectCount() == 1)
        #expect(await transport.observedCloseCount() == 1)
        #expect(await closeRecorder.recordedIDs() == [connectionID])
    }

    @Test func testMobileHostConnectionCancellationClosesTransportExactlyOnce() async {
        let connectionID = UUID()
        let transport = GatedMobileHostByteTransport()
        let closeRecorder = MobileHostConnectionCloseRecorder()
        let session = MobileHostConnection(
            id: connectionID,
            transport: transport,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { id in
                await closeRecorder.record(id)
            }
        )

        let runTask = Task {
            await session.run()
        }
        await transport.waitUntilReceiveStarted()

        runTask.cancel()
        await runTask.value
        await session.close(reason: "duplicate close after cancellation")

        #expect(await transport.observedConnectCount() == 1)
        #expect(await transport.observedCloseCount() == 1)
        #expect(await transport.observedReceiveCancellation())
        #expect(await closeRecorder.recordedIDs() == [connectionID])
    }

    @Test func testNewestAuthorizedIrohConnectionSupersedesOlderOverlap() async throws {
        let service = MobileHostService.shared
        service.debugResetMobileLifecycleStateForTesting()
        let registry = MobileHostConnectionRegistry.shared
        for connection in registry.removeAll() {
            await connection.close(reason: "test setup")
        }

        let first = ScriptedMobileHostByteTransport()
        let second = ScriptedMobileHostByteTransport()
        let authorization = try irohAdmissionContext()
        let firstTask = Task {
            await MobileHostService.acceptTransport(
                first,
                authorization: authorization,
                isCurrent: { true }
            )
        }
        await waitForMobileHostConnectionCount(1)
        try await first.enqueue(Self.mobileHostStatusFrame(id: "first"))
        _ = await first.waitForSentBufferCount(1)

        let secondTask = Task {
            await MobileHostService.acceptTransport(
                second,
                authorization: authorization,
                isCurrent: { true }
            )
        }
        await waitForMobileHostConnectionCount(2)
        try await first.enqueue(Self.mobileHostStatusFrame(id: "first-delayed"))
        _ = await first.waitForSentBufferCount(2)
        #expect(registry.count == 2)
        #expect(await second.observedCloseCount() == 0)

        try await second.enqueue(Self.mobileHostSubscribeFrame(id: "second"))
        _ = await second.waitForSentBufferCount(1)
        await waitForMobileHostConnectionCount(1)
        await first.waitForCloseCount(1)

        #expect(registry.count == 1)
        #expect(await first.observedCloseCount() == 1)
        #expect(await second.observedCloseCount() == 0)

        await first.finishReceiving()
        await second.finishReceiving()
        await firstTask.value
        await secondTask.value
        for connection in registry.removeAll() {
            await connection.close(reason: "test cleanup")
        }
        service.debugResetMobileLifecycleStateForTesting()
    }

    private static func mobileHostStatusFrame(id: String) throws -> Data {
        try MobileSyncFrameCodec.encodeFrame(
            Data("{\"id\":\"\(id)\",\"method\":\"mobile.host.status\",\"params\":{}}".utf8)
        )
    }

    private static func mobileHostSubscribeFrame(id: String) throws -> Data {
        try MobileSyncFrameCodec.encodeFrame(
            Data("{\"id\":\"\(id)\",\"method\":\"mobile.events.subscribe\",\"params\":{\"stream_id\":\"events\",\"topics\":[\"terminal.updated\"]}}".utf8)
        )
    }

    private func waitForMobileHostConnectionCount(_ expected: Int) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if MobileHostConnectionRegistry.shared.count == expected { return }
            await Task.yield()
        }
        Issue.record(
            "Timed out waiting for \(expected) mobile host connections; observed \(MobileHostConnectionRegistry.shared.count)"
        )
    }

    @Test func testIrohEventWriterTimesOutBackpressureWithInjectedClock() async {
        let stream = BlockingMobileHostIrohSendStream()
        let writer = MobileHostIrohServerEventWriter(
            openStream: { stream },
            clock: ImmediateMobileHostIrohClock(),
            sendTimeout: 3
        )

        do {
            try await writer.send(Data("framed-event".utf8))
            Issue.record("Expected independent event backpressure to time out")
        } catch {}

        let resetCodes = await stream.observedResetCodes()
        #expect(!resetCodes.isEmpty)
        #expect(resetCodes.allSatisfy { $0 == 1 })
        await writer.close()
    }
    @Test func testTerminalRenderObserverRetainsGhosttyDemandOnlyWithTerminalSubscriber() async throws {
        let service = MobileHostService.shared
        service.debugResetMobileLifecycleStateForTesting()
        let observer = MobileTerminalRenderObserver.shared
        observer.stop()
        observer.start()
        defer {
            observer.stop()
            service.debugResetMobileLifecycleStateForTesting()
        }
        await drainMobileHostMainQueue()
        #expect(!MobileHostService.debugHasEventSubscribersForTesting(topic: "terminal.updated"))
        #expect(!observer.debugIsRetainingNotificationDemandForTesting)
        let session = MobileHostConnection(
            id: UUID(),
            connection: NWConnection(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: 9)!,
                using: .tcp
            ),
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )
        await session.subscribe(streamID: "events", topics: ["terminal.updated"])
        await drainMobileHostMainQueue()
        #expect(MobileHostService.debugHasEventSubscribersForTesting(topic: "terminal.updated"))
        #expect(observer.debugIsRetainingNotificationDemandForTesting)
        _ = await session.unsubscribe(streamID: "events")
        await drainMobileHostMainQueue()
        #expect(!MobileHostService.debugHasEventSubscribersForTesting(topic: "terminal.updated"))
        #expect(!observer.debugIsRetainingNotificationDemandForTesting)
    }
    @Test func testMobileWorkspaceListHashIncludesDisplayedDirectories() {
        let workspace = Workspace(
            title: "Mobile",
            workingDirectory: "/tmp/mobile-a",
            portOrdinal: 0
        )
        let initial = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        workspace.currentDirectory = "/tmp/mobile-b"
        let afterWorkspaceDirectory = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        #expect(initial != afterWorkspaceDirectory)
        workspace.panelDirectories[UUID()] = "/tmp/mobile-terminal"
        let afterTerminalDirectory = MobileWorkspaceListObserver.summaryHashForTesting(
            tabs: [workspace],
            selectedTabID: workspace.id
        )
        #expect(afterWorkspaceDirectory != afterTerminalDirectory)
    }
    @Test func testMobileHostConnectionDoesNotPersistUnauthorizedEventSubscription() async throws {
        let connectionID = UUID()
        let recorder = MobileHostConnectionCloseRecorder()
        let socket = try MobileHostStartedTestSocket()
        defer { socket.close() }
        let session = MobileHostConnection(
            id: connectionID,
            connection: socket.connection,
            idleTimeoutNanoseconds: 1_000_000,
            authorizeRequest: { _ in
                .failure(MobileHostRPCError(code: "unauthorized", message: "no"))
            },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { id in
                await recorder.record(id)
            }
        )
        let frame = try MobileSyncFrameCodec.encodeFrame(
            Data(#"{"id":"subscribe","method":"mobile.events.subscribe","params":{"stream_id":"events","topics":["terminal.updated"]}}"#.utf8)
        )
        await session.debugHandleReceiveDataForTesting(frame)
        try await Task.sleep(nanoseconds: 25_000_000)
        await session.debugStartIdleTimeoutAfterFrameForTesting()
        for _ in 0..<100 {
            let recordedIDs = await recorder.recordedIDs()
            if !recordedIDs.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let finalRecordedIDs = await recorder.recordedIDs()
        #expect(finalRecordedIDs == [connectionID])
    }
    @Test func testMobileHostConnectionStopsBatchedFrameProcessingAfterClose() async throws {
        let connectionID = UUID()
        let requestRecorder = MobileHostConnectionRequestRecorder()
        let sessionBox = MobileHostConnectionBox()
        // Deterministic ordering signals replace the former timing race: the
        // first frame's authorize records and closes the session, then fulfills
        // `firstRecorded`. The second frame's authorize blocks on `secondGate`
        // (held until close is confirmed) instead of a fixed 100ms sleep, so the
        // close provably lands before the second frame can proceed.
        let firstRecorded = AsyncTestSignal()
        let secondAuthorizeStarted = AsyncTestSignal()
        let secondAuthorizeFinished = AsyncTestSignal()
        let secondGate = SendableSemaphore(value: 0)
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 9)!,
            using: .tcp
        )
        let session = MobileHostConnection(
            id: connectionID,
            connection: connection,
            authorizeRequest: { request in
                if request.id as? String == "second" {
                    secondAuthorizeStarted.fulfill()
                    secondGate.wait()
                    secondAuthorizeFinished.fulfill()
                }
                return nil
            },
            onAuthorizedRequest: { request in
                await requestRecorder.record(request)
                await sessionBox.close(reason: "test close after first batched frame")
                firstRecorded.fulfill()
            },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )
        await sessionBox.set(session)
        let firstFrame = try MobileSyncFrameCodec.encodeFrame(
            Data(#"{"id":"first","method":"workspace.list","params":{}}"#.utf8)
        )
        let secondFrame = try MobileSyncFrameCodec.encodeFrame(
            Data(#"{"id":"second","method":"terminal.input","params":{"text":"should-not-run"}}"#.utf8)
        )
        var batch = Data()
        batch.append(firstFrame)
        batch.append(secondFrame)
        await session.debugHandleReceiveDataForTesting(batch)
        // Wait for the first frame to record and close the connection, then
        // confirm the second frame's authorize is in flight before releasing it.
        try await firstRecorded.wait()
        try await secondAuthorizeStarted.wait()
        secondGate.signal()
        try await secondAuthorizeFinished.wait()
        // After the second authorize returns, `respond` re-checks `isClosed`
        // synchronously and drops the frame without recording it. An
        // actor-isolated round-trip flushes that synchronous tail so the
        // recorder reflects the final, settled state.
        _ = await session.isSubscribed(to: "terminal.updated")
        let recordedMethods = await requestRecorder.recordedMethods()
        #expect(recordedMethods == ["workspace.list"])
    }
    @Test func testMobileHostConnectionClosesBeforeStartingAnUnboundedRPCBatch() async throws {
        let transport = RecordingMobileHostByteTransport()
        let invocationRecorder = MobileHostAuthorizationInvocationRecorder()
        let session = MobileHostConnection(
            id: UUID(),
            transport: transport,
            authorizeRequest: { _ in
                await invocationRecorder.record()
                return nil
            },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { _ in }
        )
        let frame = try MobileSyncFrameCodec.encodeFrame(
            Data(#"{"id":"bounded","method":"workspace.list","params":{}}"#.utf8)
        )
        var batch = Data()
        for _ in 0...MobileHostRPCWorkQuota.recommendedMaximumConcurrentRequestCount {
            batch.append(frame)
        }

        await session.debugHandleReceiveDataForTesting(batch)

        #expect(await transport.observedCloseCount() == 1)
        #expect(await invocationRecorder.count() == 0)
    }
    // MARK: - Advertised mobile host capabilities
    @Test func testMobileHostAdvertisesWorkspaceActionCapabilities() {
        let capabilities = MobileHostService.mobileHostCapabilities
        #expect(capabilities.contains("workspace.actions.v1"))
        #expect(capabilities.contains("workspace.read_state.v1"))
        #expect(capabilities.contains("workspace.close.v1"))
        #expect(capabilities.contains("workspace.move.v1"))
        #expect(capabilities.contains("workspace.group_actions.v1"))
        #expect(Set(capabilities).isSuperset(of: ["workspace.task_create.v1", "terminal.render_grid.v1"]))
    }
    // MARK: - Mobile workspace.action sub-action gate
    @Test func testMobileWorkspaceActionGateAllowsOnlyPinNameAndReadStateActions() {
        for action in ["pin", "unpin", "rename", "mark_read", "mark_unread", "PIN", "UnPin", "RENAME", "MARK_READ", "Mark_Unread"] {
            #expect(
                TerminalController.mobileAllowsWorkspaceAction(action),
                "mobile workspace.action '\(action)' should be allowed"
            )
        }
        for action in [
            "move_up", "move-down", "move_top",
            "close_others", "close_above", "close_below",
            "set_color", "clear_color", "set_description", "clear_description",
            "clear_name", "close", "self_destruct", "",
        ] {
            #expect(
                !TerminalController.mobileAllowsWorkspaceAction(action),
                "mobile workspace.action '\(action)' must be rejected"
            )
        }
        #expect(!TerminalController.mobileAllowsWorkspaceAction(nil))
    }
}

private actor GatedMobileHostByteTransport: CmxByteTransport {
    private let receiveStartedStream: AsyncStream<Void>
    private let receiveStartedContinuation: AsyncStream<Void>.Continuation
    private var receiveContinuation: CheckedContinuation<Data?, Never>?
    private var connectCount = 0
    private var closeCount = 0
    private var receiveCancellationObserved = false

    init() {
        let receiveStarted = AsyncStream<Void>.makeStream()
        receiveStartedStream = receiveStarted.stream
        receiveStartedContinuation = receiveStarted.continuation
    }

    func connect() {
        connectCount += 1
    }

    func receive() async -> Data? {
        receiveStartedContinuation.yield()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    receiveCancellationObserved = true
                    continuation.resume(returning: nil)
                    return
                }
                receiveContinuation = continuation
            }
        } onCancel: {
            Task {
                await self.cancelReceive()
            }
        }
    }

    func send(_: Data) {}

    func close() {
        closeCount += 1
        receiveContinuation?.resume(returning: nil)
        receiveContinuation = nil
        receiveStartedContinuation.finish()
    }

    func waitUntilReceiveStarted() async {
        for await _ in receiveStartedStream {
            return
        }
    }

    func finishReceiving() {
        receiveContinuation?.resume(returning: nil)
        receiveContinuation = nil
    }

    func observedConnectCount() -> Int {
        connectCount
    }

    func observedCloseCount() -> Int {
        closeCount
    }

    func observedReceiveCancellation() -> Bool {
        receiveCancellationObserved
    }

    private func cancelReceive() {
        receiveCancellationObserved = true
        receiveContinuation?.resume(returning: nil)
        receiveContinuation = nil
    }
}

private actor ScriptedMobileHostByteTransport: CmxByteTransport {
    private var receiveQueue: [Data?] = []
    private var receiveWaiter: CheckedContinuation<Data?, Never>?
    private var sent: [Data] = []
    private var closeCount = 0
    private var sentWaiters: [(count: Int, continuation: CheckedContinuation<[Data], Never>)] = []
    private var closeWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !receiveQueue.isEmpty {
            return receiveQueue.removeFirst()
        }
        return await withCheckedContinuation { receiveWaiter = $0 }
    }

    func send(_ data: Data) async throws {
        sent.append(data)
        let ready = sentWaiters.filter { sent.count >= $0.count }
        sentWaiters.removeAll { sent.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume(returning: sent)
        }
    }

    func close() async {
        closeCount += 1
        let ready = closeWaiters.filter { closeCount >= $0.count }
        closeWaiters.removeAll { closeCount >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
        receiveWaiter?.resume(returning: nil)
        receiveWaiter = nil
    }

    func enqueue(_ data: Data) {
        if let receiveWaiter {
            self.receiveWaiter = nil
            receiveWaiter.resume(returning: data)
        } else {
            receiveQueue.append(data)
        }
    }

    func finishReceiving() {
        if let receiveWaiter {
            self.receiveWaiter = nil
            receiveWaiter.resume(returning: nil)
        } else {
            receiveQueue.append(nil)
        }
    }

    func waitForSentBufferCount(_ count: Int) async -> [Data] {
        if sent.count >= count {
            return sent
        }
        return await withCheckedContinuation { continuation in
            sentWaiters.append((count, continuation))
        }
    }

    func observedCloseCount() -> Int { closeCount }

    func waitForCloseCount(_ count: Int) async {
        if closeCount >= count {
            return
        }
        await withCheckedContinuation { continuation in
            closeWaiters.append((count, continuation))
        }
    }
}
