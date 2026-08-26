import CMUXMobileCore
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

    @Test func testDebugTransportCloseUsesProductionClosePathAndSupportsExactSelection() async {
        let registry = MobileHostConnectionRegistry.shared
        for connection in registry.removeAll() {
            await connection.close(reason: "test setup")
        }
        let firstID = UUID()
        let secondID = UUID()
        let firstTransport = GatedMobileHostByteTransport()
        let secondTransport = GatedMobileHostByteTransport()
        let first = MobileHostConnection(
            id: firstID,
            transport: firstTransport,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { registry.remove(id: $0) }
        )
        let second = MobileHostConnection(
            id: secondID,
            transport: secondTransport,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { registry.remove(id: $0) }
        )
        #expect(registry.insert(
            first,
            id: firstID,
            authorization: .stackBearer,
            limit: 2
        ))
        #expect(registry.insert(
            second,
            id: secondID,
            authorization: .stackBearer,
            limit: 2
        ))

        let selected = await registry.debugCloseConnections(
            connectionID: firstID
        )
        #expect(selected == [firstID])
        #expect(await firstTransport.observedCloseCount() == 1)
        #expect(await secondTransport.observedCloseCount() == 0)
        #expect(registry.count == 1)

        let remaining = await registry.debugCloseConnections(connectionID: nil)
        #expect(remaining == [secondID])
        #expect(await secondTransport.observedCloseCount() == 1)
        #expect(registry.count == 0)
    }

    @Test func testMobileHostPublishesUsableSessionOnlyAfterWorkspaceAndEventReadiness() async throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }
        let transport = ScriptedMobileHostByteTransport()
        let session = MobileHostConnection(
            id: UUID(),
            transport: transport,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { request in
                if request.method == "workspace.list" {
                    return .ok(["workspaces": [[
                        "id": "workspace-a",
                        "title": "Ready workspace",
                    ]]])
                }
                return .ok([:])
            },
            onClose: { _ in }
        )
        let runTask = Task {
            await session.run()
        }

        await transport.enqueue(try Self.mobileHostStatusFrame(id: "admission-only"))
        _ = await transport.waitForSentBufferCount(1)
        #expect(Self.retainedUsableSessionEvents().isEmpty)

        await transport.enqueue(try Self.mobileHostWorkspaceListFrame(id: "workspace"))
        _ = await transport.waitForSentBufferCount(2)
        #expect(Self.retainedUsableSessionEvents().isEmpty)

        await transport.enqueue(try Self.mobileHostTerminalSubscribeFrame(id: "subscribe"))
        _ = await transport.waitForSentBufferCount(3)

        let readyEvents = Self.retainedUsableSessionEvents()
        #expect(readyEvents.count == 1)
        let payload = readyEvents.first?["payload"] as? [String: Any]
        #expect(payload?["connection_id"] as? String == session.connectionID.uuidString)
        #expect(payload?["workspace_count"] as? Int == 1)
        #expect(payload?["stream_id"] as? String == "events")
        #expect(payload?["client_id"] as? String == "phone-a")
        #expect(payload?["transport"] as? String == "control_v1")

        await transport.enqueue(try Self.mobileHostWorkspaceListFrame(id: "workspace-again"))
        _ = await transport.waitForSentBufferCount(4)
        await transport.enqueue(try Self.mobileHostTerminalSubscribeFrame(id: "subscribe-again"))
        _ = await transport.waitForSentBufferCount(5)
        #expect(Self.retainedUsableSessionEvents().count == 1)

        await transport.finishReceiving()
        await runTask.value
    }

    @Test func testMobileHostDoesNotPublishUsableSessionWithoutARealWorkspace() async throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }
        let transport = ScriptedMobileHostByteTransport()
        let session = MobileHostConnection(
            id: UUID(),
            transport: transport,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { request in
                request.method == "workspace.list"
                    ? .ok(["workspaces": []])
                    : .ok([:])
            },
            onClose: { _ in }
        )
        let runTask = Task { await session.run() }

        await transport.enqueue(try Self.mobileHostWorkspaceListFrame(id: "empty"))
        _ = await transport.waitForSentBufferCount(1)
        await transport.enqueue(try Self.mobileHostTerminalSubscribeFrame(id: "subscribe"))
        _ = await transport.waitForSentBufferCount(2)

        #expect(Self.retainedUsableSessionEvents().isEmpty)
        await transport.finishReceiving()
        await runTask.value
    }

    @Test func testMobileHostDoesNotPublishReadinessForUnsubscribedStream() async throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }
        let transport = ScriptedMobileHostByteTransport()
        let session = MobileHostConnection(
            id: UUID(),
            transport: transport,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { request in
                request.method == "workspace.list"
                    ? .ok(["workspaces": [["id": "workspace-a"]]])
                    : .ok([:])
            },
            onClose: { _ in }
        )
        let runTask = Task { await session.run() }

        await transport.enqueue(try Self.mobileHostTerminalSubscribeFrame(id: "subscribe"))
        _ = await transport.waitForSentBufferCount(1)
        await transport.enqueue(try Self.mobileHostUnsubscribeFrame(id: "unsubscribe"))
        _ = await transport.waitForSentBufferCount(2)
        await transport.enqueue(try Self.mobileHostWorkspaceListFrame(id: "workspace"))
        _ = await transport.waitForSentBufferCount(3)

        #expect(Self.retainedUsableSessionEvents().isEmpty)
        await transport.finishReceiving()
        await runTask.value
    }

    @Test func testMobileHostPublishesReadinessOnlyAfterSubscriptionAckWrites() async throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }
        let transport = ScriptedMobileHostByteTransport()
        await transport.failSend(number: 2)
        let session = MobileHostConnection(
            id: UUID(),
            transport: transport,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { request in
                request.method == "workspace.list"
                    ? .ok(["workspaces": [["id": "workspace-a"]]])
                    : .ok([:])
            },
            onClose: { _ in }
        )
        let runTask = Task { await session.run() }

        await transport.enqueue(try Self.mobileHostWorkspaceListFrame(id: "workspace"))
        _ = await transport.waitForSentBufferCount(1)
        await transport.enqueue(try Self.mobileHostTerminalSubscribeFrame(id: "subscribe"))
        await transport.waitForCloseCount(1)

        #expect(Self.retainedUsableSessionEvents().isEmpty)
        await runTask.value
    }

    private static func mobileHostStatusFrame(id: String) throws -> Data {
        try MobileSyncFrameCodec.encodeFrame(
            Data("{\"id\":\"\(id)\",\"method\":\"mobile.host.status\",\"params\":{}}".utf8)
        )
    }

    private static func mobileHostWorkspaceListFrame(id: String) throws -> Data {
        try MobileSyncFrameCodec.encodeFrame(
            Data("{\"id\":\"\(id)\",\"method\":\"workspace.list\",\"params\":{}}".utf8)
        )
    }

    private static func mobileHostTerminalSubscribeFrame(id: String) throws -> Data {
        try MobileSyncFrameCodec.encodeFrame(
            Data(
                """
                {"id":"\(id)","method":"mobile.events.subscribe","params":{"client_id":"phone-a","stream_id":"events","topics":["workspace.updated","mobile.sync.delta","terminal.render_grid"]}}
                """.utf8
            )
        )
    }

    private static func mobileHostUnsubscribeFrame(id: String) throws -> Data {
        try MobileSyncFrameCodec.encodeFrame(
            Data(
                "{\"id\":\"\(id)\",\"method\":\"mobile.events.unsubscribe\",\"params\":{\"stream_id\":\"events\"}}".utf8
            )
        )
    }

    private static func mobileHostSubscribeFrame(id: String) throws -> Data {
        try MobileSyncFrameCodec.encodeFrame(
            Data("{\"id\":\"\(id)\",\"method\":\"mobile.events.subscribe\",\"params\":{\"stream_id\":\"events\",\"topics\":[\"terminal.updated\"]}}".utf8)
        )
    }

    private static func retainedUsableSessionEvents() -> [[String: Any]] {
        CmuxEventBus.shared.retainedSnapshot().filter {
            $0["name"] as? String == "mobile.rpc.ready"
        }
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
        #expect(capabilities.contains("workspace.metadata.v1"))
        #expect(capabilities.contains("workspace.read_state.v1"))
        #expect(capabilities.contains("workspace.close.v1"))
        #expect(capabilities.contains("workspace.move.v1"))
        #expect(capabilities.contains("workspace.group_actions.v1"))
        #expect(capabilities.contains("workspace.surfaces.v1"))
        #expect(capabilities.contains("surface.focus.v1"))
        #expect(capabilities.contains("panel.artifact.v1"))
        #expect(Set(capabilities).isSuperset(of: [
            "workspace.task_create.v1",
            MobileHostService.terminalInputOrderedCapability,
            MobileHostService.caffeineControlCapability,
            "terminal.render_grid.v1",
            "notification.feed.v1",
        ]))
    }
    @Test func testWorkspaceChangesCapabilityFollowsFeatureFlag() {
        let enabled = MobileHostService.mobileHostCapabilities(includingWorkspaceChanges: true)
        let disabled = MobileHostService.mobileHostCapabilities(includingWorkspaceChanges: false)

        #expect(enabled.contains(MobileHostService.workspaceChangesCapability))
        #expect(!disabled.contains(MobileHostService.workspaceChangesCapability))
        // The flag removes exactly the one capability and nothing else.
        #expect(
            enabled.filter { $0 != MobileHostService.workspaceChangesCapability } == disabled
        )
    }

    @Test func testTaskComposerCapabilitiesFollowFeatureFlag() {
        let enabled = MobileHostService.mobileHostCapabilities(
            includingWorkspaceChanges: true,
            includingTaskComposer: true
        )
        let disabled = MobileHostService.mobileHostCapabilities(
            includingWorkspaceChanges: true,
            includingTaskComposer: false
        )
        let taskCapabilities: Set<String> = [
            MobileHostService.taskCreateCapability,
            MobileHostService.taskAttachmentCapability,
            MobileHostService.taskModelsCapability,
            MobileHostService.taskDirectoryBrowseCapability,
            MobileHostService.taskDirectorySearchCapability,
            MobileHostService.taskDirectorySearchV2Capability,
        ]

        #expect(taskCapabilities.isSubset(of: Set(enabled)))
        #expect(Set(disabled).isDisjoint(with: taskCapabilities))
        #expect(enabled.filter { !taskCapabilities.contains($0) } == disabled)
    }

    @Test @MainActor func testMobileWorkspaceChangesFlagDefaultsAndRemoteValue() {
        let suiteName = "cmux-tests-mobile-changes-flag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var remoteValue: Any?
        let flags = CmuxFeatureFlags(
            defaults: defaults,
            remoteFlagValueProvider: { _ in remoteValue }
        )

        // Without a remote value the per-build default applies (DEBUG on for
        // dogfood, Release off); tests compile DEBUG.
        #expect(flags.isMobileWorkspaceChangesEnabled)

        remoteValue = false
        flags.applyLoadedFlags()
        #expect(!flags.isMobileWorkspaceChangesEnabled)

        remoteValue = true
        flags.applyLoadedFlags()
        #expect(flags.isMobileWorkspaceChangesEnabled)
    }

    @Test @MainActor func testMobileTaskComposerFlagDefaultsOnAndCanDisableRemotely() {
        let suiteName = "cmux-tests-mobile-task-composer-flag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var remoteValue: Any?
        let flags = CmuxFeatureFlags(
            defaults: defaults,
            remoteFlagValueProvider: { key in
                key == CmuxFeatureFlags.mobileTaskComposerFlag.key ? remoteValue : nil
            }
        )

        #expect(flags.isMobileTaskComposerEnabled)

        remoteValue = false
        flags.applyLoadedFlags()
        #expect(!flags.isMobileTaskComposerEnabled)

        remoteValue = true
        flags.applyLoadedFlags()
        #expect(flags.isMobileTaskComposerEnabled)
    }

    // MARK: - Mobile workspace.action sub-action gate
    @Test func testMobileWorkspaceActionGateAllowsIdentityAndReadStateActions() {
        for action in [
            "pin", "unpin", "rename",
            "set_description", "clear_description", "set_color", "clear_color",
            "mark_read", "mark_unread",
            "PIN", "UnPin", "RENAME", "SET_DESCRIPTION", "CLEAR_COLOR", "MARK_READ", "Mark_Unread",
        ] {
            #expect(
                TerminalController.mobileAllowsWorkspaceAction(action),
                "mobile workspace.action '\(action)' should be allowed"
            )
        }
        for action in [
            "move_up", "move-down", "move_top",
            "close_others", "close_above", "close_below",
            "clear_name", "close", "self_destruct", "",
        ] {
            #expect(
                !TerminalController.mobileAllowsWorkspaceAction(action),
                "mobile workspace.action '\(action)' must be rejected"
            )
        }
        #expect(!TerminalController.mobileAllowsWorkspaceAction(nil))
        #expect(TerminalController.mobileWorkspaceActionKey(" SET-DESCRIPTION ") == "set_description")
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
    private enum Failure: Error {
        case scriptedSend
    }

    private var receiveQueue: [Data?] = []
    private var receiveWaiter: CheckedContinuation<Data?, Never>?
    private var sent: [Data] = []
    private var closeCount = 0
    private var failedSendNumbers: Set<Int> = []
    private var sendCount = 0
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
        sendCount += 1
        if failedSendNumbers.contains(sendCount) {
            throw Failure.scriptedSend
        }
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

    func failSend(number: Int) {
        failedSendNumbers.insert(number)
    }

    func waitForCloseCount(_ count: Int) async {
        if closeCount >= count {
            return
        }
        await withCheckedContinuation { continuation in
            closeWaiters.append((count, continuation))
        }
    }
}
