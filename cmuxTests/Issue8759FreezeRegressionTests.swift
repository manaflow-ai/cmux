import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct Issue8759FreezeRegressionTests {
    @Test func resumeApprovalSigningSecretDefersAndCoalescesMainThreadLoad() {
        let expected = Data("issue-8759-signing-secret".utf8)
        let loader = LockedCallCounter(result: expected)
        let scheduler = LockedJobScheduler()
        let cache = SurfaceResumeApprovalSigningSecretCache(
            loader: { loader.call() },
            schedule: { scheduler.append($0) }
        )

        #expect(cache.value(isMainThread: true) == nil)
        #expect(cache.value(isMainThread: true) == nil)
        #expect(loader.callCount == 0, "main-thread reads must not run the Keychain loader")
        #expect(scheduler.count == 1, "concurrent autosave panels must share one pending load")

        scheduler.runNext()

        #expect(cache.value(isMainThread: true) == expected)
        #expect(loader.callCount == 1)
        #expect(scheduler.count == 0)
    }

    @Test func hangWatchdogCapturesOncePerStarvationEpisode() {
        var state = MainThreadHangWatchdogState(stallThreshold: 8)
        state.recordHeartbeat(at: 100)

        #expect(!state.shouldCapture(at: 107.999))
        #expect(state.shouldCapture(at: 108))
        #expect(!state.shouldCapture(at: 109), "one stall must produce only one capture")

        state.recordHeartbeat(at: 110)
        #expect(!state.shouldCapture(at: 117.999))
        #expect(state.shouldCapture(at: 118), "a heartbeat starts a new starvation episode")
    }
}

private final class LockedCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let result: Data
    private var calls = 0

    init(result: Data) {
        self.result = result
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func call() -> Data? {
        lock.withLock {
            calls += 1
            return result
        }
    }
}

private final class LockedJobScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [@Sendable () -> Void] = []

    var count: Int {
        lock.withLock { jobs.count }
    }

    func append(_ job: @escaping @Sendable () -> Void) {
        lock.withLock {
            jobs.append(job)
        }
    }

    func runNext() {
        let job = lock.withLock {
            jobs.isEmpty ? nil : jobs.removeFirst()
        }
        job?()
    }
}
