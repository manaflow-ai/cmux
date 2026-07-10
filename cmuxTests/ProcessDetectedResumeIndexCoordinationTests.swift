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
struct ProcessDetectedResumeIndexCoordinationTests {
    @Test
    func confirmedTerminationCoreSaveDoesNotStartAnExtraColdScan() async {
        let loadStarted = DispatchSemaphore(value: 0)
        let releaseLoad = DispatchSemaphore(value: 0)
        defer { releaseLoad.signal() }
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                events.withLock { $0.append("load") }
                loadCount.withLock { $0 += 1 }
                loadStarted.signal()
                releaseLoad.wait()
                return (
                    index: .empty,
                    surfaceResumeBindingIndex: .empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { Self.temporaryDirectory(named: "confirmed-cold").path }
        )
        let coordinator = TerminationResumeIndexCoordinator()
        let watchdog = TerminationWatchdog(
            onFire: {},
            scheduleDeadline: { _, _ in events.withLock { $0.append("watchdog") } }
        )
        let capture = ConfirmedTerminationSessionCapture(watchdog: watchdog)

        capture.prepare {
            events.withLock { $0.append("core") }
            #expect(coordinator.current() == nil)
        }
        let task = Task { @MainActor in
            _ = await capture.capture {
                events.withLock { $0.append("capture") }
                return await coordinator.load(coordinatedBy: sharedIndex)
            }
            guard !Task.isCancelled else { return }
            events.withLock { $0.append("complete") }
        }

        #expect(loadCount.withLock { $0 } == 0)
        #expect(events.withLock { $0 } == ["core", "watchdog"])
        #expect(await Self.wait(for: loadStarted))
        #expect(loadCount.withLock { $0 } == 1)
        releaseLoad.signal()
        await task.value
        #expect(events.withLock { $0 } == ["core", "watchdog", "capture", "load", "complete"])
    }

    @Test
    func unavailableTerminationCaptureIsMemoized() async {
        let timeoutWaiter = TerminationCoordinatorTimeoutWaiter()
        let firstLoadStarted = DispatchSemaphore(value: 0)
        let secondLoadStarted = DispatchSemaphore(value: 0)
        let releaseFirstLoad = DispatchSemaphore(value: 0)
        let releaseSecondLoad = DispatchSemaphore(value: 0)
        defer {
            releaseFirstLoad.signal()
            releaseSecondLoad.signal()
        }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let unavailableResult: SharedLiveAgentIndexLoader.LoadResult = (
            index: .empty,
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: [],
            forkValidatedPanels: []
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                (invocation == 1 ? firstLoadStarted : secondLoadStarted).signal()
                (invocation == 1 ? releaseFirstLoad : releaseSecondLoad).wait()
                return unavailableResult
            },
            generationTimeoutWaiter: { await timeoutWaiter.wait() },
            hookStoreDirectoryProvider: { Self.temporaryDirectory(named: "unavailable").path }
        )
        let coordinator = TerminationResumeIndexCoordinator()

        let first = Task { @MainActor in await coordinator.load(coordinatedBy: sharedIndex) }
        #expect(await Self.wait(for: firstLoadStarted))
        await timeoutWaiter.waitUntilPendingCount(1)
        await timeoutWaiter.fireNext()
        #expect(await first.value == nil)
        sharedIndex.latestCompletedLoadResult = unavailableResult
        #expect(
            coordinator.current().map { _ in true } == nil,
            "A memoized unavailable termination capture must override an older shared cache."
        )

        let second = Task { @MainActor in await coordinator.load(coordinatedBy: sharedIndex) }
        let didStartSecondLoad = await Self.wait(for: secondLoadStarted, timeout: 0.2)
        if didStartSecondLoad {
            releaseSecondLoad.signal()
        }
        let secondResult = await second.value

        #expect(!didStartSecondLoad, "A completed unavailable capture must not launch another full scan.")
        #expect(secondResult == nil)
        #expect(loadCount.withLock { $0 } == 1)
        releaseFirstLoad.signal()
        await timeoutWaiter.cancelAll()
    }

    @Test
    func quickQuitDuringPrewarmQueuesPostConfirmationCapture() async {
        let loadStarted = DispatchSemaphore(value: 0)
        let secondLoadStarted = DispatchSemaphore(value: 0)
        let releaseLoad = DispatchSemaphore(value: 0)
        let autosaveReachedSuspension = DispatchSemaphore(value: 0)
        let terminationReachedSuspension = DispatchSemaphore(value: 0)
        defer {
            releaseLoad.signal()
            releaseLoad.signal()
            releaseLoad.signal()
        }
        let loadState = OSAllocatedUnfairLock(initialState: (active: 0, maximum: 0, count: 0))
        let processArgumentLoadCount = OSAllocatedUnfairLock(initialState: 0)
        let hookDirectory = Self.temporaryDirectory(named: "consumers")
        let homeDirectory = Self.temporaryDirectory(named: "home")
        defer {
            try? FileManager.default.removeItem(at: hookDirectory)
            try? FileManager.default.removeItem(at: homeDirectory)
        }
        let workspaceId = UUID()
        let panelId = UUID()
        let processId = 8_733_201
        let processSnapshot = Self.tmuxProcessSnapshot(
            processId: processId,
            workspaceId: workspaceId,
            panelId: panelId
        )
        let loader = SharedLiveAgentIndexLoader(
            homeDirectory: homeDirectory.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            processSnapshotProvider: {
                let invocation = loadState.withLock { state in
                    state.active += 1
                    state.maximum = max(state.maximum, state.active)
                    state.count += 1
                    return state.count
                }
                (invocation == 1 ? loadStarted : secondLoadStarted).signal()
                releaseLoad.wait()
                loadState.withLock { $0.active -= 1 }
                return processSnapshot
            },
            capturedAtProvider: { 42 },
            processArgumentsProvider: { requestedProcessId in
                let invocation = processArgumentLoadCount.withLock { count in
                    count += 1
                    return count
                }
                guard requestedProcessId == processId else { return nil }
                let session = invocation == 1 ? "pre-confirmation" : "post-confirmation"
                return CmuxTopProcessArguments(
                    arguments: ["/opt/homebrew/bin/tmux", "attach-session", "-t", session],
                    environment: ["PWD": "/tmp/\(session)"]
                )
            },
            processIdentityProvider: { _ in nil }
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: { loader.loadResultSynchronously() },
            hookStoreDirectoryProvider: { hookDirectory.path }
        )
        let terminationCoordinator = TerminationResumeIndexCoordinator()

        let hibernationCapture = Task { @MainActor in
            await sharedIndex.scopedIndexCapturedAfterRequest()
        }
        #expect(await Self.wait(for: loadStarted))

        let autosaveCapture = Task { @MainActor in
            Task { @MainActor in autosaveReachedSuspension.signal() }
            return await ProcessDetectedResumeIndexes.load(coordinatedBy: sharedIndex)
        }
        #expect(await Self.wait(for: autosaveReachedSuspension))

        let terminationCapture = Task { @MainActor in
            Task { @MainActor in terminationReachedSuspension.signal() }
            return await terminationCoordinator.load(coordinatedBy: sharedIndex)
        }
        #expect(await Self.wait(for: terminationReachedSuspension))
        #expect(terminationCoordinator.current().map { _ in true } == nil)
        #expect(terminationCoordinator.current().map { _ in true } == nil)
        let startedSecondLoad = await Self.wait(for: secondLoadStarted, timeout: 0.2)
        #expect(
            !startedSecondLoad,
            "The post-confirmation capture must queue behind the older prewarm without overlapping it."
        )

        releaseLoad.signal()
        #expect(await Self.wait(for: secondLoadStarted))
        releaseLoad.signal()
        _ = await hibernationCapture.value
        let resumeIndexes = await autosaveCapture.value
        let terminationIndexes = await terminationCapture.value
        #expect(Self.bindingSession(in: resumeIndexes, workspaceId: workspaceId, panelId: panelId) == "pre-confirmation")
        #expect(Self.bindingSession(in: terminationIndexes, workspaceId: workspaceId, panelId: panelId) == "post-confirmation")

        let firstWillTerminateIndexes = terminationCoordinator.current()
        let secondWillTerminateIndexes = terminationCoordinator.current()
        #expect(Self.bindingSession(in: firstWillTerminateIndexes, workspaceId: workspaceId, panelId: panelId) == "post-confirmation")
        #expect(Self.bindingSession(in: secondWillTerminateIndexes, workspaceId: workspaceId, panelId: panelId) == "post-confirmation")
        #expect(loadState.withLock { $0.count } == 2)
        #expect(loadState.withLock { $0.maximum } == 1)
        #expect(
            processArgumentLoadCount.withLock { $0 } == 2,
            "Each generation must reuse one process-argument decode across its agent and tmux indexes."
        )
    }

    @Test
    func autosaveTicksReuseFreshCaptureUntilScopeOrTTLChanges() async {
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let now = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 100))
        let processScopeFingerprint = OSAllocatedUnfairLock(initialState: Set(["scope-a"]))
        let hookDirectory = Self.temporaryDirectory(named: "ttl")
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadCount.withLock { $0 += 1 }
                return (
                    index: .empty,
                    surfaceResumeBindingIndex: .empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: processScopeFingerprint.withLock { $0 },
                    forkValidatedPanels: []
                )
            },
            processScopeFingerprintProvider: { processScopeFingerprint.withLock { $0 } },
            hookStoreDirectoryProvider: { hookDirectory.path },
            dateProvider: { now.withLock { $0 } }
        )

        #expect(await Self.loadSucceeded(from: sharedIndex))
        now.withLock { $0 = Date(timeIntervalSince1970: 108) }
        #expect(await Self.loadSucceeded(from: sharedIndex))
        now.withLock { $0 = Date(timeIntervalSince1970: 116) }
        #expect(await Self.loadSucceeded(from: sharedIndex))
        #expect(loadCount.withLock { $0 } == 1)

        now.withLock { $0 = Date(timeIntervalSince1970: 124) }
        processScopeFingerprint.withLock { $0 = ["scope-b"] }
        #expect(await Self.loadSucceeded(from: sharedIndex))
        #expect(loadCount.withLock { $0 } == 2)

        now.withLock { $0 = Date(timeIntervalSince1970: 185) }
        #expect(await Self.loadSucceeded(from: sharedIndex))
        #expect(loadCount.withLock { $0 } == 3)
    }

    @Test
    func scopedResumeCaptureFeedsStaleTolerantReadsWithoutSuccessor() async {
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let hookDirectory = Self.temporaryDirectory(named: "effective-index")
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let workspaceId = UUID()
        let panelId = UUID()
        let loadedIndex = SharedLiveAgentIndexLoadCoalescingTests.index(
            workspaceId: workspaceId,
            panelId: panelId,
            sessionId: "fresh-scoped-session"
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadCount.withLock { $0 += 1 }
                return (
                    index: loadedIndex,
                    surfaceResumeBindingIndex: .empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { hookDirectory.path }
        )

        #expect(await Self.loadSucceeded(from: sharedIndex))
        #expect(sharedIndex.currentResumeIndexesSchedulingRefresh().map { _ in true } == true)
        #expect(sharedIndex.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId == "fresh-scoped-session")
        let refreshed = await sharedIndex.indexRefreshingIfNeeded()
        #expect(refreshed?.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId == "fresh-scoped-session")
        #expect(loadCount.withLock { $0 } == 1)
    }

    @Test
    func unavailableTerminationIndexesPreserveCoreTerminalSnapshot() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        defer { AppDelegate.shared = previousAppDelegate }
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        #expect(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t preserved",
                cwd: "/tmp/preserved",
                checkpointId: "preserved",
                source: "process-detected",
                updatedAt: 42
            ),
            panelId: panelId
        ))

        let plan = TerminationResumeIndexSavePlan.resolve(nil)
        #expect(
            plan.restorableAgentIndex != nil,
            "Core snapshot fallback must suppress the snapshot builder's cold refresh."
        )
        let snapshot = try #require(app.debugBuildSessionSnapshotForTesting(
            includeScrollback: false,
            surfaceResumeBindingIndex: plan.surfaceResumeBindingIndex
        ))
        let savedWorkspace = try #require(snapshot.windows.first?.tabManager.workspaces.first)

        #expect(plan.usesCoreSnapshotFallback)
        #expect(savedWorkspace.workspaceId == workspace.id)
        #expect(savedWorkspace.panels.first(where: { $0.id == panelId })?
            .terminal?.resumeBinding?.checkpointId == "preserved")
    }

    @Test
    func blockedTerminationCaptureCannotDelayCorePersistenceOrWatchdog() async {
        let captureStarted = DispatchSemaphore(value: 0)
        let releaseCapture = DispatchSemaphore(value: 0)
        defer { releaseCapture.signal() }
        let didPersistCoreSnapshot = OSAllocatedUnfairLock(initialState: false)
        let didComplete = OSAllocatedUnfairLock(initialState: false)
        let watchdogFired = OSAllocatedUnfairLock(initialState: false)
        let scheduledFire = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
        let watchdog = TerminationWatchdog(
            onFire: { watchdogFired.withLock { $0 = true } },
            scheduleDeadline: { _, fire in scheduledFire.withLock { $0 = fire } }
        )
        let capture = ConfirmedTerminationSessionCapture(watchdog: watchdog)

        capture.prepare {
            didPersistCoreSnapshot.withLock { $0 = true }
        }
        let task = Task { @MainActor in
            _ = await capture.capture {
                captureStarted.signal()
                _ = await Self.wait(for: releaseCapture)
                return nil
            }
            guard !Task.isCancelled else { return }
            didComplete.withLock { $0 = true }
        }

        #expect(didPersistCoreSnapshot.withLock { $0 })
        let fire = scheduledFire.withLock { $0 }
        #expect(fire.map { _ in true } == true)
        #expect(await Self.wait(for: captureStarted))
        #expect(!didComplete.withLock { $0 })
        fire?()
        #expect(watchdogFired.withLock { $0 })

        task.cancel()
        releaseCapture.signal()
        await task.value
        #expect(!didComplete.withLock { $0 })
    }

    private static func temporaryDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-resume-index-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private static func tmuxProcessSnapshot(
        processId: Int,
        workspaceId: UUID,
        panelId: UUID
    ) -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot(
            processes: [CmuxTopProcessInfo(
                pid: processId,
                parentPID: 1,
                name: "tmux: client",
                path: "/opt/homebrew/bin/tmux",
                ttyDevice: nil,
                cmuxWorkspaceID: workspaceId,
                cmuxSurfaceID: panelId,
                cmuxAttributionReason: "cmux-test",
                processGroupID: processId,
                terminalProcessGroupID: processId,
                cpuPercent: 0,
                residentBytes: 0,
                virtualBytes: 0,
                threadCount: 1
            )],
            sampledAt: Date(timeIntervalSince1970: 42),
            includesProcessDetails: true
        )
    }

    private static func bindingSession(
        in indexes: ProcessDetectedResumeIndexes?,
        workspaceId: UUID,
        panelId: UUID
    ) -> String? {
        indexes?.surfaceResumeBindingIndex.binding(
            workspaceId: workspaceId,
            panelId: panelId
        )?.checkpointId
    }

    private static func loadSucceeded(from sharedIndex: SharedLiveAgentIndex) async -> Bool {
        await ProcessDetectedResumeIndexes.load(coordinatedBy: sharedIndex).map { _ in true } == true
    }

    nonisolated private static func wait(
        for semaphore: DispatchSemaphore,
        timeout: TimeInterval = 10
    ) async -> Bool {
        await Task.detached {
            semaphore.wait(timeout: .now() + timeout) == .success
        }.value
    }
}

private actor TerminationCoordinatorTimeoutWaiter {
    private var pending: [CheckedContinuation<Bool, Never>] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            pending.append(continuation)
            let ready = countWaiters.filter { pending.count >= $0.count }
            countWaiters.removeAll { pending.count >= $0.count }
            ready.forEach { $0.continuation.resume() }
        }
    }

    func waitUntilPendingCount(_ count: Int) async {
        guard pending.count < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count: count, continuation: continuation))
        }
    }

    func fireNext() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: true)
    }

    func cancelAll() {
        let continuations = pending
        pending.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume(returning: false) }
    }
}
