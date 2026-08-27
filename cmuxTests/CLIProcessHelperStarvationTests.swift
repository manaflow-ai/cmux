import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The app-host bundle runs Swift Testing suites in parallel, and many of them
/// drive the bundled CLI through the shared process helpers while mock socket
/// servers block in `accept`/`read` on libdispatch's global queues. Once the
/// global worker pool is exhausted, a helper that observes the child's exit
/// from a global-queue block never learns the child finished, so the test
/// reports `status: 15, timedOut: true` for a CLI that returned in
/// milliseconds. This suite saturates the pool the way a busy parallel phase
/// does and asserts the shared helpers still complete promptly.
final class CLIProcessHelperStarvationTests: XCTestCase {
    private static let blockerCount = 320

    private func withSaturatedGlobalQueue<T>(_ body: () -> T) -> T {
        let release = DispatchSemaphore(value: 0)
        let drained = DispatchGroup()
        for _ in 0..<Self.blockerCount {
            drained.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                release.wait()
                drained.leave()
            }
        }
        defer {
            for _ in 0..<Self.blockerCount {
                release.signal()
            }
            _ = drained.wait(timeout: .now() + 10)
        }
        // Give the pool a moment to hand its workers to the blockers.
        Thread.sleep(forTimeInterval: 0.2)
        return body()
    }

    func testSharedRunProcessCompletesWhileGlobalQueueIsSaturated() {
        let support = CLINotifyProcessIntegrationRegressionTests(invocation: nil)
        let started = Date()
        let result = withSaturatedGlobalQueue {
            support.runProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", "printf ok"],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 3
            )
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(result.timedOut, "helper lost the child's exit while the global queue was saturated")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "ok")
        XCTAssertLessThan(elapsed, 3, "a trivial child took \(elapsed)s under a saturated global queue")
    }

    func testClaudeHookRunProcessCompletesWhileGlobalQueueIsSaturated() {
        let support = ClaudeHookSurfaceResolutionSwiftTests()
        let started = Date()
        let result = withSaturatedGlobalQueue {
            support.runProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", "cat"],
                environment: ["PATH": "/usr/bin:/bin"],
                standardInput: "echoed",
                timeout: 3
            )
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(result.timedOut, "helper lost the child's exit while the global queue was saturated")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "echoed")
        XCTAssertLessThan(elapsed, 3, "a trivial child took \(elapsed)s under a saturated global queue")
    }

    func testLiveDeliveryHookProcessCompletesWhileGlobalQueueIsSaturated() throws {
        let context = try ClaudeHookLiveDeliveryHarness.makeContext(name: "starvation-live-delivery")
        defer { context.cleanup() }
        let started = Date()
        let result = withSaturatedGlobalQueue {
            ClaudeHookLiveDeliveryHarness.runHookProcess(
                context: context,
                arguments: ["--version"],
                environment: ["PATH": "/usr/bin:/bin", "CMUX_CLI_SENTRY_DISABLED": "1"],
                standardInput: ""
            )
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(result.timedOut, "helper lost the child's exit while the global queue was saturated")
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertLessThan(elapsed, 5, "a trivial child took \(elapsed)s under a saturated global queue")
    }
}
