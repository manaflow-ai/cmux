import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SharedLiveAgentIndexFingerprintInvalidationTests {
    @Test
    func processScopeFingerprintChangesAcrossExec() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        func fingerprint(name: String, path: String, startSeconds: Int64 = 100) -> Set<String> {
            let process = CmuxTopProcessInfo(
                pid: 42,
                processIdentity: AgentPIDProcessIdentity(
                    pid: 42,
                    startSeconds: startSeconds,
                    startMicroseconds: 7
                ),
                parentPID: 1,
                name: name,
                path: path,
                ttyDevice: nil,
                cmuxWorkspaceID: workspaceID,
                cmuxSurfaceID: surfaceID,
                cmuxAttributionReason: "test",
                processGroupID: 42,
                terminalProcessGroupID: 42,
                cpuPercent: 0,
                residentBytes: 0,
                virtualBytes: 0,
                threadCount: 1
            )
            let snapshot = CmuxTopProcessSnapshot(
                processes: [process],
                sampledAt: Date(),
                includesProcessDetails: true
            )
            return SharedLiveAgentIndexLoader.processScopeFingerprint(
                from: snapshot,
                processArgumentsProvider: { _ in
                    CmuxTopProcessArguments(arguments: [path, "--session", "test"], environment: [:])
                }
            )
        }

        #expect(
            fingerprint(name: "cmux-agent-shim", path: "/usr/local/bin/cmux-agent-shim")
                != fingerprint(name: "claude", path: "/usr/local/bin/claude"),
            "A same-PID exec must invalidate process-scoped resume metadata."
        )
        #expect(
            fingerprint(name: "claude", path: "/usr/local/bin/claude", startSeconds: 100)
                != fingerprint(name: "claude", path: "/usr/local/bin/claude", startSeconds: 101),
            "PID reuse must invalidate process-scoped resume metadata."
        )
    }

    @Test
    func cacheFingerprintChangesWithAgentRegistryConfiguration() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-registry-fingerprint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = CmuxTopProcessSnapshot(
            processes: [],
            sampledAt: Date(),
            includesProcessDetails: true
        )
        func fingerprint(resumeCommand: String) -> Set<String> {
            let registration = CmuxVaultAgentRegistration(
                id: "custom-agent",
                name: "Custom Agent",
                detect: CmuxVaultAgentDetectRule(processName: "custom-agent"),
                sessionIdSource: .argvOption("--session"),
                resumeCommand: resumeCommand
            )
            return SharedLiveAgentIndexLoader(
                homeDirectory: root.path,
                registry: CmuxVaultAgentRegistry(registrations: [registration]),
                processSnapshotProvider: { snapshot }
            ).loadResultSynchronously().processScopeFingerprint
        }

        #expect(
            fingerprint(resumeCommand: "custom-agent --session {{sessionId}}")
                != fingerprint(resumeCommand: "custom-agent resume {{sessionId}}"),
            "Changing effective agent configuration must invalidate cached resume metadata."
        )
    }

    @Test
    func fingerprintMismatchInvalidatesPublishedIndex() async {
        let now = Date()
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-published-index-invalidation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let cachedResult: SharedLiveAgentIndex.LoadResult = (
            index: .empty,
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: ["scope-a"],
            forkValidatedPanels: []
        )
        let sharedIndex = SharedLiveAgentIndex(
            processScopeFingerprintProvider: { ["scope-b"] },
            hookStoreDirectoryProvider: { hookDirectory.path },
            dateProvider: { now }
        )
        sharedIndex.applyReloadedResult(
            cachedResult,
            validationPanelsByPanelID: [:],
            generationID: UUID()
        )
        sharedIndex.latestCompletedLoadResult = cachedResult
        sharedIndex.latestCompletedAt = now
        for ordinal in 1 ... SharedLiveAgentIndex.maximumConcurrentPhysicalLoads {
            let generationID = UUID()
            sharedIndex.refreshGenerationsByID[generationID] = .init(
                id: generationID,
                ordinal: UInt64(ordinal),
                phase: .capturing,
                publication: .scoped,
                validationPanelsByPanelID: [:]
            )
        }

        _ = await sharedIndex.resumeIndexesRefreshingIfNeeded(maximumAge: 60)

        #expect(
            sharedIndex.cachedIndex() == nil,
            "A process-scope mismatch must invalidate the separately published index."
        )
    }

    @Test
    func refreshStartedDuringFingerprintValidationBecomesAuthoritative() async {
        let workspaceId = UUID()
        let panelId = UUID()
        let fingerprintStarted = DispatchSemaphore(value: 0)
        let releaseFingerprint = DispatchSemaphore(value: 0)
        defer { releaseFingerprint.signal() }
        let now = Date.now
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-refresh-during-fingerprint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let cachedResult: SharedLiveAgentIndex.LoadResult = (
            index: SharedLiveAgentIndexLoadCoalescingTests.index(
                workspaceId: workspaceId,
                panelId: panelId,
                sessionId: "cached-session"
            ),
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: ["scope"],
            forkValidatedPanels: []
        )
        let refreshResult: SharedLiveAgentIndex.LoadResult = (
            index: SharedLiveAgentIndexLoadCoalescingTests.index(
                workspaceId: workspaceId,
                panelId: panelId,
                sessionId: "refresh-session"
            ),
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: ["scope"],
            forkValidatedPanels: []
        )
        let sharedIndex = SharedLiveAgentIndex(
            processScopeFingerprintProvider: {
                fingerprintStarted.signal()
                releaseFingerprint.wait()
                return ["scope"]
            },
            hookStoreDirectoryProvider: { hookDirectory.path },
            dateProvider: { now }
        )
        sharedIndex.latestCompletedLoadResult = cachedResult
        sharedIndex.latestCompletedAt = now

        let read = Task { @MainActor in
            await sharedIndex.resumeIndexesRefreshingIfNeeded(maximumAge: 60)
        }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: fingerprintStarted))
        let generationID = UUID()
        sharedIndex.refreshGenerationsByID[generationID] = .init(
            id: generationID,
            ordinal: 1,
            phase: .capturing,
            publication: .scoped,
            validationPanelsByPanelID: [:]
        )
        sharedIndex.refreshTasksByID[generationID] = Task { refreshResult }
        sharedIndex.refreshTailID = generationID
        releaseFingerprint.signal()

        let result = await read.value
        let sessionId = result?.restorableAgentIndex
            .snapshot(workspaceId: workspaceId, panelId: panelId)?
            .sessionId
        #expect(
            sessionId == "refresh-session",
            "A refresh that starts during cache validation must supersede the older cached result."
        )
    }

    @Test
    func matchingWarmValidationPreservesForkAvailability() async {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let now = Date()
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-warm-validation-fork-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let cachedResult: SharedLiveAgentIndex.LoadResult = (
            index: SharedLiveAgentIndexLoadCoalescingTests.index(
                workspaceId: workspaceId,
                panelId: panelId,
                sessionId: "validated-session"
            ),
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: ["scope"],
            forkValidatedPanels: [panelKey]
        )
        let sharedIndex = SharedLiveAgentIndex(
            processScopeFingerprintProvider: { ["scope"] },
            hookStoreDirectoryProvider: { hookDirectory.path },
            dateProvider: { now }
        )
        sharedIndex.applyReloadedResult(
            cachedResult,
            validationPanelsByPanelID: [:],
            generationID: UUID()
        )
        sharedIndex.latestCompletedLoadResult = cachedResult
        sharedIndex.latestCompletedAt = now
        #expect(
            sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) != nil
        )

        #expect(await sharedIndex.resumeIndexesRefreshingIfNeeded(maximumAge: 60) != nil)

        #expect(
            sharedIndex.snapshotForForkAvailability(workspaceId: workspaceId, panelId: panelId) != nil,
            "A matching warm validation must preserve the existing fork availability proof."
        )
    }

    @Test(arguments: [false, true])
    func expiredCacheIsRejectedWhenRefreshIsUnavailable(joinExistingRefresh: Bool) async {
        var now = Date()
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-expired-index-unavailable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let cachedResult: SharedLiveAgentIndex.LoadResult = (
            index: .empty,
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: [],
            forkValidatedPanels: []
        )
        let sharedIndex = SharedLiveAgentIndex(
            processScopeFingerprintProvider: { [] },
            hookStoreDirectoryProvider: { hookDirectory.path },
            dateProvider: { now }
        )

        sharedIndex.latestCompletedLoadResult = cachedResult
        sharedIndex.latestCompletedAt = now
        now = now.addingTimeInterval(61)

        if joinExistingRefresh {
            let generationID = UUID()
            sharedIndex.refreshGenerationsByID[generationID] = .init(
                id: generationID,
                ordinal: 1,
                phase: .capturing,
                publication: .scoped,
                validationPanelsByPanelID: [:]
            )
            sharedIndex.refreshTasksByID[generationID] = Task { nil }
            sharedIndex.refreshTailID = generationID
        } else {
            for ordinal in 1 ... SharedLiveAgentIndex.maximumConcurrentPhysicalLoads {
                let generationID = UUID()
                sharedIndex.refreshGenerationsByID[generationID] = .init(
                    id: generationID,
                    ordinal: UInt64(ordinal),
                    phase: .capturing,
                    publication: .scoped,
                    validationPanelsByPanelID: [:]
                )
            }
        }

        let refreshed = await sharedIndex.resumeIndexesRefreshingIfNeeded(maximumAge: 60)

        #expect(
            refreshed == nil,
            "An unavailable refresh must not revive an index older than the requested maximum age."
        )
    }

    @Test
    func timedOutCaptureDoesNotReturnFingerprintMismatchedCache() async {
        let timeoutWaiter = ManualGenerationTimeoutWaiter()
        let secondLoadStarted = DispatchSemaphore(value: 0)
        let releaseSecondLoad = DispatchSemaphore(value: 0)
        defer { releaseSecondLoad.signal() }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let processScopeFingerprint = OSAllocatedUnfairLock(initialState: Set(["scope-a"]))
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fingerprint-invalidation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                if invocation == 2 {
                    secondLoadStarted.signal()
                    releaseSecondLoad.wait()
                }
                return (
                    index: .empty,
                    surfaceResumeBindingIndex: .empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: processScopeFingerprint.withLock { $0 },
                    forkValidatedPanels: []
                )
            },
            processScopeFingerprintProvider: { processScopeFingerprint.withLock { $0 } },
            generationTimeoutWaiter: { await timeoutWaiter.wait() },
            hookStoreDirectoryProvider: { hookDirectory.path }
        )

        let initial = await sharedIndex.resumeIndexesRefreshingIfNeeded()
        #expect(initial != nil)
        await timeoutWaiter.waitUntilPendingCount(1)

        processScopeFingerprint.withLock { $0 = ["scope-b"] }
        let refresh = Task { @MainActor in
            await sharedIndex.resumeIndexesRefreshingIfNeeded()
        }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: secondLoadStarted))
        await timeoutWaiter.waitUntilPendingCount(2)
        await timeoutWaiter.fireLast()

        let refreshed = await refresh.value
        #expect(
            refreshed.map { _ in true } == nil,
            "An unavailable replacement capture must not revive the cache whose fingerprint just mismatched."
        )
        #expect(
            sharedIndex.cachedResumeIndexes().map { _ in true } == nil,
            "Fingerprint-invalidated indexes must not remain available to synchronous termination consumers."
        )

        releaseSecondLoad.signal()
        await timeoutWaiter.cancelAll()
    }

    @Test
    func warmCacheValidationReturnsUnavailableWhenFingerprintScanStalls() async {
        let timeoutGate = TimeoutGate()
        let fingerprintStarted = DispatchSemaphore(value: 0)
        let releaseFingerprint = DispatchSemaphore(value: 0)
        let readCompleted = DispatchSemaphore(value: 0)
        defer { releaseFingerprint.signal() }
        let now = Date()
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-stalled-cache-validation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let cachedResult: SharedLiveAgentIndex.LoadResult = (
            index: .empty,
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: ["scope"],
            forkValidatedPanels: []
        )
        let sharedIndex = SharedLiveAgentIndex(
            processScopeFingerprintProvider: {
                fingerprintStarted.signal()
                releaseFingerprint.wait()
                return ["scope"]
            },
            generationTimeoutWaiter: {
                await timeoutGate.wait()
                return true
            },
            hookStoreDirectoryProvider: { hookDirectory.path },
            dateProvider: { now }
        )
        sharedIndex.latestCompletedLoadResult = cachedResult
        sharedIndex.latestCompletedAt = now

        let read = Task { @MainActor in
            let result = await sharedIndex.resumeIndexesRefreshingIfNeeded(maximumAge: 60)
            readCompleted.signal()
            return result
        }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: fingerprintStarted))
        await timeoutGate.open()
        let returnedBeforeFingerprint = await SharedLiveAgentIndexLoadCoalescingTests.wait(
            for: readCompleted,
            timeout: 1
        )
        #expect(
            returnedBeforeFingerprint,
            "A stalled fingerprint scan must resolve through the generation deadline."
        )

        releaseFingerprint.signal()
        let result = await read.value
        #expect(result == nil)
        #expect(sharedIndex.cachedResumeIndexes() == nil)
    }

    private actor TimeoutGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let waiters = self.waiters
            self.waiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}
