import CMUXMobileCore
import Foundation
@preconcurrency import Network
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Connection lifecycle & idle timeouts
extension MobileHostAuthorizationTests {
    func testMobileHostConnectionCloseOnlyClearsConnectionTracking() {
        let service = MobileHostService.shared
        let connectionID = UUID()

        service.debugResetMobileLifecycleStateForTesting()
        service.debugRecordClientIDForTesting("ios-client", connectionID: connectionID)

        XCTAssertEqual(service.debugTrackedClientIDsForTesting(connectionID: connectionID), Set(["ios-client"]))

        service.debugRemoveConnectionForTesting(id: connectionID)

        XCTAssertNil(service.debugTrackedClientIDsForTesting(connectionID: connectionID))
    }

    func testIdleMobileConnectionDoesNotKeepRequestActivityBusy() {
        MobileHostRequestActivity.resetForTesting()
        MobileHostRequestActivity.beginConnection()
        defer {
            MobileHostRequestActivity.endConnection()
            MobileHostRequestActivity.resetForTesting()
        }

        XCTAssertFalse(MobileHostRequestActivity.hasActiveRequest)
        XCTAssertFalse(MobileHostRequestActivity.hasRecentActivity(within: 60))
        XCTAssertEqual(MobileHostRequestActivity.quietDelay(for: 60), 0)
    }

    func testMobileHostConnectionCloseLeavesViewportReportsForPollingClient() {
        let service = MobileHostService.shared
        let terminalController = TerminalController.shared
        let connectionID = UUID()
        let surfaceID = UUID()

        service.debugResetMobileLifecycleStateForTesting()
        terminalController.debugResetMobileViewportReportsForTesting()
        terminalController.debugSetMobileViewportReportForTesting(
            surfaceID: surfaceID,
            clientID: "ios-client",
            columns: 54,
            rows: 42
        )
        terminalController.debugSetMobileViewportReportForTesting(
            surfaceID: surfaceID,
            clientID: "ipad-client",
            columns: 84,
            rows: 15
        )
        service.debugRecordClientIDForTesting("ios-client", connectionID: connectionID)

        service.debugRemoveConnectionForTesting(id: connectionID)

        XCTAssertEqual(
            terminalController.debugMobileViewportReportClientIDsForTesting(surfaceID: surfaceID),
            Set(["ios-client", "ipad-client"]),
            "Mobile RPC connections are short lived, so socket close must not clear viewport reports before their TTL expires."
        )

        terminalController.debugResetMobileViewportReportsForTesting()
    }

    func testMobileHostIgnoresStaleListenerStateCallbacks() {
        let service = MobileHostService.shared
        let currentGeneration = UUID()
        let staleGeneration = UUID()

        service.debugResetMobileLifecycleStateForTesting()
        service.debugSetListenerStateForTesting(
            generation: currentGeneration,
            usesEphemeralFallback: true,
            port: 61234
        )

        service.debugHandleListenerStateForTesting(
            .failed(.posix(.ECONNRESET)),
            generation: staleGeneration
        )

        XCTAssertEqual(service.debugListenerGenerationForTesting(), currentGeneration)
        XCTAssertTrue(service.debugListenerUsesEphemeralFallbackForTesting())
        XCTAssertEqual(service.debugListenerPortForTesting(), 61234)

        service.debugHandleListenerStateForTesting(.cancelled, generation: staleGeneration)

        XCTAssertEqual(service.debugListenerGenerationForTesting(), currentGeneration)
        XCTAssertTrue(service.debugListenerUsesEphemeralFallbackForTesting())
        XCTAssertEqual(service.debugListenerPortForTesting(), 61234)
    }

    func testMobileHostWaitingListenerDoesNotPublishRoutes() {
        let service = MobileHostService.shared
        let generation = UUID()

        service.stop()
        service.debugResetMobileLifecycleStateForTesting()
        service.debugSetListenerStateForTesting(
            generation: generation,
            usesEphemeralFallback: false,
            port: 61234
        )

        service.debugHandleListenerStateForTesting(.waiting(.posix(.EADDRINUSE)), generation: generation)

        let status = service.statusSnapshot()
        XCTAssertFalse(status.isRunning)
        XCTAssertNil(status.port)
        XCTAssertTrue(status.routes.isEmpty)
        XCTAssertNil(service.debugListenerPortForTesting())
    }

    func testMobileHostConnectionClosesWhenFirstFrameTimesOut() async throws {
        let connectionID = UUID()
        let recorder = MobileHostConnectionCloseRecorder()
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 9)!,
            using: .tcp
        )
        let session = MobileHostConnection(
            id: connectionID,
            connection: connection,
            firstFrameTimeoutNanoseconds: 1_000_000,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { id in
                await recorder.record(id)
            }
        )

        await session.debugStartFirstFrameTimeoutForTesting()

        for _ in 0..<100 {
            let recordedIDs = await recorder.recordedIDs()
            if !recordedIDs.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let finalRecordedIDs = await recorder.recordedIDs()
        XCTAssertEqual(finalRecordedIDs, [connectionID])
    }

    func testMobileHostConnectionClosesWhenIdleAfterFirstFrame() async throws {
        let connectionID = UUID()
        let recorder = MobileHostConnectionCloseRecorder()
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 9)!,
            using: .tcp
        )
        let session = MobileHostConnection(
            id: connectionID,
            connection: connection,
            idleTimeoutNanoseconds: 1_000_000,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { id in
                await recorder.record(id)
            }
        )

        await session.debugStartIdleTimeoutAfterFrameForTesting()

        for _ in 0..<100 {
            let recordedIDs = await recorder.recordedIDs()
            if !recordedIDs.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let finalRecordedIDs = await recorder.recordedIDs()
        XCTAssertEqual(finalRecordedIDs, [connectionID])
    }

    func testMobileHostConnectionKeepsSubscribedEventStreamPastIdleTimeout() async throws {
        let connectionID = UUID()
        let recorder = MobileHostConnectionCloseRecorder()
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 9)!,
            using: .tcp
        )
        let session = MobileHostConnection(
            id: connectionID,
            connection: connection,
            idleTimeoutNanoseconds: 1_000_000,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) },
            onClose: { id in
                await recorder.record(id)
            }
        )

        await session.subscribe(streamID: "events", topics: ["terminal.updated"])
        await session.debugStartIdleTimeoutAfterFrameForTesting()
        try await Task.sleep(nanoseconds: 25_000_000)
        let subscribedCloseIDs = await recorder.recordedIDs()
        XCTAssertTrue(subscribedCloseIDs.isEmpty)

        _ = await session.unsubscribe(streamID: "events")
        for _ in 0..<100 {
            let recordedIDs = await recorder.recordedIDs()
            if !recordedIDs.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let finalRecordedIDs = await recorder.recordedIDs()
        XCTAssertEqual(finalRecordedIDs, [connectionID])
    }

    func testMobileHostConnectionDoesNotPersistUnauthorizedEventSubscription() async throws {
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
        XCTAssertEqual(finalRecordedIDs, [connectionID])
    }

    func testMobileHostConnectionStopsBatchedFrameProcessingAfterClose() async throws {
        let connectionID = UUID()
        let requestRecorder = MobileHostConnectionRequestRecorder()
        let sessionBox = MobileHostConnectionBox()
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
                    do {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    } catch {}
                }
                return nil
            },
            onAuthorizedRequest: { request in
                await requestRecorder.record(request)
                await sessionBox.close(reason: "test close after first batched frame")
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

        for _ in 0..<100 {
            let recordedMethods = await requestRecorder.recordedMethods()
            if !recordedMethods.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let recordedMethods = await requestRecorder.recordedMethods()
        XCTAssertEqual(recordedMethods, ["workspace.list"])
    }

    // MARK: - Advertised mobile host capabilities

}
