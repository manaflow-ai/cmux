import XCTest
import CMUXWorkstream

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FeedCoordinatorTests: XCTestCase {
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
