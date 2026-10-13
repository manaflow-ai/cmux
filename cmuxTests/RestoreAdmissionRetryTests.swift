import CMUXAgentLaunch
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for #12084: a restore must not give up on the first
/// `busy` answer from the app's ownership scan.
///
/// Right after a relaunch several restored panes fire their session-start
/// hooks at once, so the app's ownership-sensitive process scan cannot settle
/// for a few seconds and answers `busy` with `retryable`. Aborting on that
/// answer left a bare shell whose binding then retired, so resumes only worked
/// once. The CLI now waits through a bounded delay budget.
@Suite struct RestoreAdmissionRetryPolicyTests {
    private struct AdmissionFailure: Error {
        let retryable: Bool
    }

    private static func isRetryable(_ error: Error) -> Bool {
        (error as? AdmissionFailure)?.retryable == true
    }

    @Test
    func retryableBusyIsRetriedUntilAdmitted() throws {
        var sends = 0
        var slept: [TimeInterval] = []
        var retriesAnnounced: [Int] = []

        let response = try AgentRestoreAdmissionRetry().response(
            delays: [0.5, 1, 2],
            sleep: { slept.append($0) },
            onRetry: { retriesAnnounced.append($0) },
            isRetryable: Self.isRetryable
        ) { () throws -> [String: Bool] in
            sends += 1
            if sends < 3 { throw AdmissionFailure(retryable: true) }
            return ["admitted": true]
        }

        #expect(response["admitted"] == true)
        #expect(sends == 3)
        #expect(slept == [0.5, 1])
        #expect(retriesAnnounced == [0, 1])
    }

    @Test
    func exhaustedBudgetPropagatesTheLastBusyAnswer() {
        var sends = 0
        var slept: [TimeInterval] = []

        #expect(throws: AdmissionFailure.self) {
            try AgentRestoreAdmissionRetry().response(
                delays: [0.5, 1],
                sleep: { slept.append($0) },
                isRetryable: Self.isRetryable
            ) { () throws -> Bool in
                sends += 1
                throw AdmissionFailure(retryable: true)
            }
        }
        #expect(sends == 3)
        #expect(slept == [0.5, 1])
    }

    @Test
    func nonRetryableFailuresAreNotRetried() {
        var sends = 0
        var slept: [TimeInterval] = []

        #expect(throws: AdmissionFailure.self) {
            try AgentRestoreAdmissionRetry().response(
                delays: [0.5, 1],
                sleep: { slept.append($0) },
                isRetryable: Self.isRetryable
            ) { () throws -> Bool in
                sends += 1
                throw AdmissionFailure(retryable: false)
            }
        }
        #expect(sends == 1)
        #expect(slept.isEmpty)
    }

    @Test
    func defaultBudgetWaitsLongEnoughForAHookStormToSubside() {
        let total = AgentRestoreAdmissionRetry().delaysSeconds.reduce(0, +)
        #expect(total >= 30)
        #expect(total <= 60)
        #expect(AgentRestoreAdmissionRetry().delaysSeconds.first.map { $0 <= 1 } == true)
    }
}

/// Ownership refreshes must finish while either Pi or another agent writes
/// its hook store. Main's fresh-scan contract (#12166) supersedes this branch's
/// per-kind quiescence checks: admission revalidates process identity and
/// claims the launch after this scan, without waiting for hook traffic to stop.
@MainActor
@Suite(.serialized)
struct LiveAgentIndexRelevantChurnTests {
    private static func makeHookStoreDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-relevant-churn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// An index whose loader rewrites `churnedFilename` on every load, the way
    /// a hook landing mid-scan does.
    private static func makeChurningIndex(
        directory: URL,
        churnedFilename: String,
        loadCount: OSAllocatedUnfairLock<Int>
    ) -> SharedLiveAgentIndex {
        let churnedFile = directory.appendingPathComponent(churnedFilename)
        return SharedLiveAgentIndex(
            indexLoader: {
                let count = loadCount.withLock { $0 += 1; return $0 }
                try? Data("{\"version\":1,\"sessions\":{},\"load\":\(count)}".utf8)
                    .write(to: churnedFile, options: .atomic)
                return (
                    index: RestorableAgentSessionIndex.empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { directory.path }
        )
    }

    /// Holds the index loader open so a scan can outlive one request's deadline.
    private actor OwnershipScanGate {
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        private(set) var loadCount = 0

        func load() async -> SharedLiveAgentIndexLoader.LoadResult {
            loadCount += 1
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            if !released {
                await withCheckedContinuation { releaseWaiter = $0 }
            }
            return (
                index: RestorableAgentSessionIndex.empty,
                liveAgentProcessFingerprint: [],
                processScopeFingerprint: [],
                forkValidatedPanels: []
            )
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    /// #20186: every restored pane asks for its own ownership decision. When
    /// the shared scan outlived the earliest request's deadline, that request
    /// cancelled the scan and failed every other waiter, so with many panes
    /// some deadline always expired first and no restore was ever admitted.
    @Test("A timed-out ownership request leaves the shared scan to later requests")
    func timedOutOwnershipRequestKeepsSharedScanForLaterRequests() async throws {
        let directory = try Self.makeHookStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = OwnershipScanGate()
        let index = SharedLiveAgentIndex(
            indexLoader: { await gate.load() },
            hookStoreDirectoryProvider: { directory.path },
            ownershipRefreshTimeoutNanoseconds: 1_500_000_000
        )

        let first = Task { await index.indexForOwnershipDecision() }
        await gate.waitUntilStarted()
        // Stagger the second request so its deadline lands after the first's,
        // the way restored panes reach admission one after another.
        try await Task.sleep(for: .milliseconds(750))
        let second = Task { await index.indexForOwnershipDecision() }

        guard case .timedOut = await first.value else {
            Issue.record("The first request should outlive its deadline while the scan is held")
            return
        }
        await gate.release()

        guard case .index = await second.value else {
            Issue.record("The first request's timeout discarded the scan the second request awaited")
            return
        }
        #expect(await gate.loadCount == 1)
    }

    @Test(arguments: ["claude-hook-sessions.json", "pi-hook-sessions.json"])
    func hookStoreChurnDoesNotBlockOwnershipDecision(filename: String) async throws {
        let directory = try Self.makeHookStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let index = Self.makeChurningIndex(
            directory: directory,
            churnedFilename: filename,
            loadCount: loadCount
        )

        let outcome = await index.indexForOwnershipDecision()

        guard case .index(let refreshed) = outcome else {
            Issue.record("Hook-store churn blocked a fresh ownership scan: \(outcome)")
            return
        }
        #expect(refreshed.isComplete)
        #expect(loadCount.withLock { $0 } >= 1)
    }
}
