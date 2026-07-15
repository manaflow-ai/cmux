import Dispatch
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Shared live-agent hook-store invalidation", .serialized)
struct SharedLiveAgentIndexHookStoreInvalidationTests {
    @Test
    func hookEventReloadCadenceScalesWithIndexedSessionCount() async {
        let loadStarted = DispatchSemaphore(value: 0)
        var now = Date(timeIntervalSince1970: 100)
        let cachedResult: SharedLiveAgentIndex.LoadResult = (
            index: Self.index(entryCount: 270),
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: [],
            forkValidatedPanels: []
        )
        #expect(cachedResult.index.entryCount == 270)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadStarted.signal()
                return cachedResult
            },
            hookStoreDirectoryProvider: {
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("cmux-indexed-cadence-\(UUID().uuidString)").path
            },
            dateProvider: { now }
        )
        sharedIndex.applyReloadedResult(
            cachedResult,
            validationPanelsByPanelID: [:],
            generationID: UUID()
        )

        now.addTimeInterval(10)
        sharedIndex.handleHookStoreChange()

        #expect(
            !(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: loadStarted, timeout: 0.5)),
            "A 270-entry index must use the 30-second backpressure cap even when no agent PID is live."
        )
    }

    @Test
    func directoryWatcherIgnoresWritesOutsideHookSessionStores() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-change-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hookStoreURL = root.appendingPathComponent("claude-hook-sessions.json")
        try Data("{\"sessions\":{}}".utf8).write(to: hookStoreURL, options: .atomic)

        let loadStarted = DispatchSemaphore(value: 0)
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        var now = Date(timeIntervalSince1970: 100)
        let cachedResult: SharedLiveAgentIndex.LoadResult = (
            index: .empty,
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: [],
            forkValidatedPanels: []
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadCount.withLock { $0 += 1 }
                loadStarted.signal()
                return cachedResult
            },
            hookStoreDirectoryProvider: { root.path },
            dateProvider: { now }
        )
        sharedIndex.applyReloadedResult(
            cachedResult,
            validationPanelsByPanelID: [:],
            generationID: UUID()
        )
        sharedIndex.latestCompletedLoadResult = cachedResult
        sharedIndex.latestCompletedAt = now
        sharedIndex.ensureWatchingHookStoreDirectory()

        now.addTimeInterval(10)
        try Data("unrelated\n".utf8).write(
            to: root.appendingPathComponent("events.jsonl"),
            options: .atomic
        )

        let unrelatedWriteStartedLoad = await SharedLiveAgentIndexLoadCoalescingTests.wait(
            for: loadStarted,
            timeout: 0.5
        )
        #expect(
            !unrelatedWriteStartedLoad,
            "Directory writes outside *-hook-sessions.json must not invalidate the process index."
        )
        guard !unrelatedWriteStartedLoad else { return }
        #expect(sharedIndex.cachedResumeIndexes() != nil)

        try Data("{\"sessions\":{},\"revision\":1}".utf8).write(
            to: hookStoreURL,
            options: .atomic
        )

        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: loadStarted))
        #expect(loadCount.withLock { $0 } == 1)
    }

    nonisolated private static func index(entryCount: Int) -> RestorableAgentSessionIndex {
        var detected: [
            RestorableAgentSessionIndex.PanelKey:
                RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry
        ] = [:]
        for ordinal in 0..<entryCount {
            let key = RestorableAgentSessionIndex.PanelKey(
                workspaceId: UUID(),
                panelId: UUID()
            )
            detected[key] = (
                snapshot: SessionRestorableAgentSnapshot(
                    kind: .codex,
                    sessionId: "indexed-cadence-\(ordinal)",
                    workingDirectory: "/tmp/cmux-indexed-cadence",
                    launchCommand: nil
                ),
                updatedAt: TimeInterval(ordinal),
                processIDs: [],
                agentProcessIDs: [],
                sessionIDSource: .explicit
            )
        }
        return RestorableAgentSessionIndex.load(
            homeDirectory: "/tmp/cmux-indexed-cadence-missing-home",
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: detected,
            processArgumentsProvider: { _ in nil },
            processIdentityProvider: { _ in nil }
        )
    }

    @Test
    func debouncedHookChangeRetriesAfterPhysicalLoadCapacityReturns() async {
        let timeoutWaiter = ManualGenerationTimeoutWaiter()
        let firstStarted = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let successorStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        let releaseSuccessor = DispatchSemaphore(value: 0)
        defer {
            releaseFirst.signal()
            releaseSecond.signal()
            releaseSuccessor.signal()
        }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        var now = Date(timeIntervalSince1970: 100)
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-change-capacity-\(UUID().uuidString)", isDirectory: true)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                switch invocation {
                case 1:
                    firstStarted.signal()
                    releaseFirst.wait()
                case 2:
                    secondStarted.signal()
                    releaseSecond.wait()
                default:
                    successorStarted.signal()
                    releaseSuccessor.wait()
                }
                return (
                    index: SharedLiveAgentIndexLoadCoalescingTests.index(
                        workspaceId: UUID(),
                        panelId: UUID(),
                        sessionId: "debounced-capacity-\(invocation)"
                    ),
                    surfaceResumeBindingIndex: .empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            generationTimeoutWaiter: { await timeoutWaiter.wait() },
            hookStoreDirectoryProvider: { hookDirectory.path },
            dateProvider: { now }
        )
        sharedIndex.applyReloadedResult(
            (
                index: .empty,
                surfaceResumeBindingIndex: .empty,
                liveAgentProcessFingerprint: [],
                processScopeFingerprint: [],
                forkValidatedPanels: []
            ),
            validationPanelsByPanelID: [:],
            generationID: UUID()
        )

        sharedIndex.handleHookStoreChange()
        let first = Task { @MainActor in await sharedIndex.resumeIndexesCapturedAfterRequest() }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: firstStarted))
        await timeoutWaiter.waitUntilPendingCount(1)
        await timeoutWaiter.fireNext()
        #expect(await first.value == nil)

        let second = Task { @MainActor in await sharedIndex.resumeIndexesCapturedAfterRequest() }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: secondStarted))
        await timeoutWaiter.waitUntilPendingCount(1)
        await timeoutWaiter.fireNext()
        #expect(await second.value == nil)

        now.addTimeInterval(5)
        sharedIndex.scheduleHookStoreRefresh()

        #expect(
            sharedIndex.changePending,
            "A timer-fired hook refresh rejected at capacity must remain pending."
        )
        #expect(loadCount.withLock { $0 } == 2)
        releaseSecond.signal()
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: successorStarted))
        #expect(!sharedIndex.changePending)
        #expect(loadCount.withLock { $0 } == 3)

        releaseSuccessor.signal()
        releaseFirst.signal()
        await timeoutWaiter.cancelAll()
    }

    @Test
    func completedWorkspaceRefreshRateLimitsPendingHookChange() async {
        let firstStarted = DispatchSemaphore(value: 0)
        let firstPublished = DispatchSemaphore(value: 0)
        let successorStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSuccessor = DispatchSemaphore(value: 0)
        defer {
            releaseFirst.signal()
            releaseSuccessor.signal()
        }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let now = Date(timeIntervalSince1970: 100)
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-change-rate-limit-\(UUID().uuidString)", isDirectory: true)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                (invocation == 1 ? firstStarted : successorStarted).signal()
                (invocation == 1 ? releaseFirst : releaseSuccessor).wait()
                return (
                    index: SharedLiveAgentIndexLoadCoalescingTests.index(
                        workspaceId: UUID(),
                        panelId: UUID(),
                        sessionId: "rate-limited-drain-\(invocation)"
                    ),
                    surfaceResumeBindingIndex: .empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { hookDirectory.path },
            dateProvider: { now }
        )
        let observer = NotificationCenter.default.addObserver(
            forName: .sharedLiveAgentIndexDidChange,
            object: sharedIndex,
            queue: nil
        ) { _ in
            firstPublished.signal()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        sharedIndex.startBackgroundRefresh()
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: firstStarted))

        sharedIndex.handleHookStoreChange()
        #expect(sharedIndex.changePending)

        releaseFirst.signal()
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: firstPublished))
        #expect(
            !(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: successorStarted, timeout: 0.2)),
            "A hook-store change drained after publication must retain the event reload interval."
        )
        #expect(loadCount.withLock { $0 } == 1)
    }

    @Test
    func hookStoreChangeRevokesWarmCacheBeforeDebouncedRefresh() async {
        let workspaceId = UUID()
        let panelId = UUID()
        let loadStarted = DispatchSemaphore(value: 0)
        let releaseLoad = DispatchSemaphore(value: 0)
        let readCompleted = DispatchSemaphore(value: 0)
        defer { releaseLoad.signal() }
        let now = Date()
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-change-warm-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let cachedResult: SharedLiveAgentIndex.LoadResult = (
            index: SharedLiveAgentIndexLoadCoalescingTests.index(
                workspaceId: workspaceId,
                panelId: panelId,
                sessionId: "stale-session"
            ),
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: ["scope"],
            forkValidatedPanels: []
        )
        let refreshedResult: SharedLiveAgentIndex.LoadResult = (
            index: SharedLiveAgentIndexLoadCoalescingTests.index(
                workspaceId: workspaceId,
                panelId: panelId,
                sessionId: "fresh-session"
            ),
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: ["scope"],
            forkValidatedPanels: []
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadStarted.signal()
                releaseLoad.wait()
                return refreshedResult
            },
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

        sharedIndex.handleHookStoreChange()

        #expect(
            sharedIndex.cachedResumeIndexes() == nil,
            "A known hook-store change must immediately revoke warm resume authority."
        )
        let read = Task { @MainActor in
            let result = await sharedIndex.resumeIndexesRefreshingIfNeeded(maximumAge: 60)
            readCompleted.signal()
            return result
        }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: loadStarted, timeout: 0.2))
        #expect(
            !(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: readCompleted, timeout: 0.2)),
            "A post-event read must await fresh filesystem authority."
        )

        releaseLoad.signal()
        let result = await read.value
        #expect(
            result?.restorableAgentIndex.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId
                == "fresh-session"
        )
    }
}
