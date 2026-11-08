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
            schedule: {
                scheduler.append($0)
                return nil
            }
        )

        #expect(cache.value(isMainThread: true) == .pending)
        #expect(cache.value(isMainThread: true) == .pending)
        #expect(loader.callCount == 0, "main-thread reads must not run the Keychain loader")
        #expect(scheduler.count == 1, "concurrent autosave panels must share one pending load")

        let completion = LockedResultRecorder()
        cache.preload { completion.record($0) }
        #expect(!cache.isReady)
        #expect(completion.values.isEmpty, "in-flight loads must not publish a terminal nil result")

        scheduler.runNext()

        #expect(cache.value(isMainThread: true) == .ready(expected))
        #expect(cache.isReady)
        #expect(completion.values == [expected])
        #expect(loader.callCount == 1)
        #expect(scheduler.count == 0)
    }

    @Test func resumeApprovalSigningSecretRetainsScheduledTaskUntilResolution() async throws {
        let expected = Data("issue-8759-retained-task-secret".utf8)
        let loader = LockedCallCounter(result: expected)
        let completion = LockedResultRecorder()
        let gate = AsyncStream<Void>.makeStream()
        let taskRecorder = LockedTaskRecorder()
        let cache = SurfaceResumeApprovalSigningSecretCache(
            loader: { loader.call() },
            schedule: { job in
                let task = Task.detached {
                    var iterator = gate.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    guard !Task.isCancelled else { return }
                    job()
                }
                taskRecorder.record(task)
                return task
            }
        )

        #expect(cache.value(isMainThread: true) == .pending)
        cache.preload { completion.record($0) }
        let task = try #require(taskRecorder.task)

        gate.continuation.yield()
        gate.continuation.finish()
        await task.value

        #expect(cache.value(isMainThread: true) == .ready(expected))
        #expect(completion.values == [expected])
        #expect(loader.callCount == 1)
    }

    @Test func resumeApprovalSigningSecretCancelsScheduledTaskOnDeinit() async throws {
        let loader = LockedCallCounter(result: Data("unused-secret".utf8))
        let suspension = AsyncStream<Void>.makeStream()
        let taskRecorder = LockedTaskRecorder()
        var cache: SurfaceResumeApprovalSigningSecretCache? = SurfaceResumeApprovalSigningSecretCache(
            loader: { loader.call() },
            schedule: { job in
                let task = Task.detached {
                    for await _ in suspension.stream {}
                    guard !Task.isCancelled else { return }
                    job()
                }
                taskRecorder.record(task)
                return task
            }
        )

        #expect(cache?.value(isMainThread: true) == .pending)
        let task = try #require(taskRecorder.task)
        cache = nil

        #expect(task.isCancelled)
        suspension.continuation.finish()
        await task.value
        #expect(loader.callCount == 0)
    }

    @Test func resumeApprovalLookupWaitsForSigningSecretResolution() {
        let binding = SurfaceResumeBindingSnapshot(
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli",
            autoResume: true,
            approvalPolicy: .auto,
            approvalRecordId: "unverified-record"
        )
        let missingStore = URL(fileURLWithPath: "/tmp/cmux-missing-\(UUID().uuidString).json")

        let pending = SurfaceResumeApprovalStore.applyingStoredApprovalLookup(
            to: binding,
            fileURL: missingStore,
            signingSecretResolution: .pending
        )
        guard case .pendingSigningSecret = pending else {
            Issue.record("a pending secret must not produce an approval decision")
            return
        }
        let pendingPresentation = SurfaceResumeApprovalStore.bindingWithoutStoredApproval(to: binding)
        #expect(pendingPresentation.command == binding.command)
        #expect(pendingPresentation.approvalPolicy == .manual)
        #expect(!pendingPresentation.allowsAutomaticResume)
        #expect(pendingPresentation.approvalRecordId == nil)

        let unavailable = SurfaceResumeApprovalStore.applyingStoredApprovalLookup(
            to: binding,
            fileURL: missingStore,
            signingSecretResolution: .ready(nil)
        )
        guard case let .resolved(effectiveBinding) = unavailable else {
            Issue.record("a definitively unavailable secret must resolve the existing fallback policy")
            return
        }
        #expect(effectiveBinding.approvalPolicy == .manual)
        #expect(!effectiveBinding.allowsAutomaticResume)
        #expect(effectiveBinding.approvalRecordId == nil)
    }

    @Test func trustedResumeProposalsDoNotWaitForSigningSecretResolution() {
        for source in ["agent-hook", "process-detected"] {
            let binding = SurfaceResumeBindingSnapshot(
                command: "codex resume trusted-session",
                cwd: "/tmp/project",
                source: source,
                autoResume: true
            )

            let result = SurfaceResumeApprovalStore.approvalProposalContext(
                for: binding,
                signingSecretResolution: .pending
            )
            guard case let .resolved(context) = result else {
                Issue.record("\(source) must not depend on the signing secret")
                continue
            }
            #expect(context.effectiveBinding.allowsAutomaticResume)
            #expect(context.effectiveBinding.approvalPolicy == .auto)
            #expect(context.existingRecord == nil)
        }
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

        let store = MainThreadHangCaptureStore(
            directory: directory,
            maximumCaptureCount: 2,
            fileManager: .default
        )
        let prepared = try #require(store.prepareCapture(
            capturedAt: Date(timeIntervalSince1970: 10),
            processIdentifier: 42,
            stallDuration: 8,
            appVersion: "test",
            appBuild: "1"
        ))

        let remaining = try Set(FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(remaining.contains("newest.metadata.txt"))
        #expect(remaining.contains("newest.sample.txt"))
        #expect(remaining.contains(prepared.metadataURL.lastPathComponent))
        #expect(!remaining.contains("oldest.metadata.txt"))
        #expect(!remaining.contains("oldest.sample.txt"))
        #expect(!remaining.contains("middle.metadata.txt"))
        #expect(!remaining.contains("middle.sample.txt"))
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

private final class LockedTaskRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTask: Task<Void, Never>?

    var task: Task<Void, Never>? {
        lock.withLock { recordedTask }
    }

    func record(_ task: Task<Void, Never>) {
        lock.withLock {
            recordedTask = task
        }
    }
}
