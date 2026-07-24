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

        let completion = LockedResultRecorder()
        cache.preload { completion.record($0) }
        #expect(!cache.isReady)
        #expect(completion.values.isEmpty, "in-flight loads must not publish a terminal nil result")

        scheduler.runNext()

        #expect(cache.value(isMainThread: true) == expected)
        #expect(cache.isReady)
        #expect(completion.values == [expected])
        #expect(loader.callCount == 1)
        #expect(scheduler.count == 0)
    }

    @Test func hangWatchdogCapturesOncePerStarvationEpisode() {
        var state = MainThreadHangWatchdogState(stallThreshold: 8)
        state.recordHeartbeat(at: 100)

        let beforeThreshold = state.shouldCapture(at: 107.999)
        let reachesThreshold = state.shouldCapture(at: 108)
        let duplicateCapture = state.shouldCapture(at: 109)
        #expect(!beforeThreshold)
        #expect(reachesThreshold)
        #expect(!duplicateCapture, "one stall must produce only one capture")

        state.recordHeartbeat(at: 110)
        let beforeNextThreshold = state.shouldCapture(at: 117.999)
        let reachesNextThreshold = state.shouldCapture(at: 118)
        #expect(!beforeNextThreshold)
        #expect(reachesNextThreshold, "a heartbeat starts a new starvation episode")
    }

    @Test func hangWatchdogCaptureRetentionKeepsNewestBoundedSet() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hang-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for (index, name) in ["oldest", "middle", "newest"].enumerated() {
            for suffix in [".metadata.txt", ".sample.txt"] {
                let file = directory.appendingPathComponent(name + suffix)
                try Data(name.utf8).write(to: file)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index + 1))],
                    ofItemAtPath: file.path
                )
            }
        }

        MainThreadHangCaptureRetentionPolicy(maximumCaptureCount: 2)
            .prepareForNewCapture(in: directory)

        let remaining = try Set(FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(remaining == ["newest.metadata.txt", "newest.sample.txt"])
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

private final class LockedResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Data] = []

    var values: [Data] {
        lock.withLock { recorded }
    }

    func record(_ value: Data?) {
        if let value {
            lock.withLock { recorded.append(value) }
        }
    }
}
