import XCTest
import CMUXWorkstream

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FeedCoordinatorTests: XCTestCase {
    @MainActor
    func testActivityAutoPaginationLoadsOnePagePerUnderfilledViewportMeasurement() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-feed-auto-page-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let persistence = WorkstreamPersistence(fileURL: tmp)
        for i in 0..<7 {
            try await persistence.append(WorkstreamItem(
                workstreamId: "opencode-auto-page-\(i)",
                source: .opencode,
                kind: .stop,
                payload: .stop(reason: "done \(i)")
            ))
        }

        let store = WorkstreamStore(
            persistence: persistence,
            ringCapacity: 20,
            initialLoadLimit: 1,
            historyPageSize: 2
        )
        await store.start()
        FeedCoordinator.shared.install(store: store)

        let model = FeedPanelViewModel()
        model.setActivityAutoPaginationActive(true)
        model.noteActivityViewportHeight(360)
        model.noteActivityContentHeight(40)
        await model.waitForActivityAutoPaginationIdleForTesting()

        XCTAssertEqual(model.items.map(\.workstreamId), [
            "opencode-auto-page-4",
            "opencode-auto-page-5",
            "opencode-auto-page-6",
        ])
        XCTAssertTrue(model.hasMorePersistedItems)

        model.noteActivityContentHeight(40)
        await model.waitForActivityAutoPaginationIdleForTesting()
        XCTAssertEqual(model.items.count, 3, "Same geometry must not auto-load the next page again")

        model.noteActivityContentHeight(220)
        await model.waitForActivityAutoPaginationIdleForTesting()
        XCTAssertEqual(model.items.map(\.workstreamId), [
            "opencode-auto-page-2",
            "opencode-auto-page-3",
            "opencode-auto-page-4",
            "opencode-auto-page-5",
            "opencode-auto-page-6",
        ])
        XCTAssertTrue(model.hasMorePersistedItems)

        model.noteActivityContentHeight(520)
        await model.waitForActivityAutoPaginationIdleForTesting()
        XCTAssertEqual(model.items.count, 5, "Filled viewport must leave remaining history for manual pagination")
    }

    func testBlockingIngestExpiresItemWhenHookTimesOut() async {
        await MainActor.run {
            let store = WorkstreamStore(ringCapacity: 10)
            FeedCoordinator.shared.install(store: store)
        }

        let event = WorkstreamEvent(
            sessionId: "claude-timeout-test",
            hookEventName: .permissionRequest,
            source: "claude",
            cwd: "/tmp",
            toolName: "Bash",
            toolInputJSON: #"{"command":"true"}"#,
            requestId: "timeout-request"
        )

        let done = DispatchSemaphore(value: 0)
        let resultBox = IngestResultBox()

        DispatchQueue.global(qos: .userInitiated).async {
            resultBox.value = FeedCoordinator.shared.ingestBlocking(
                event: event,
                waitTimeout: 0.05
            )
            done.signal()
        }

        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)

        guard case .timedOut = resultBox.value else {
            XCTFail("expected feed.push to time out")
            return
        }

        let status = await MainActor.run {
            FeedCoordinator.shared.store.items.first?.status
        }
        guard case .expired = status else {
            XCTFail("timed-out hook item should be expired")
            return
        }
    }
}

private final class IngestResultBox: @unchecked Sendable {
    var value: FeedCoordinator.IngestBlockingResult?
}
