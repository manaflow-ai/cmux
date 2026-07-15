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
@Suite("Termination resume-index invalidation", .serialized)
struct TerminationResumeIndexCoordinatorInvalidationTests {
    @Test
    func confirmedTerminationReusesPreparedUpdateRelaunchAuthority() async throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let directory = try Self.temporaryDirectory(named: "update-confirmation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                return Self.loadResult(
                    checkpointId: invocation == 1 ? "updater-prepared" : "after-terminal-stop",
                    workspaceId: workspaceId,
                    panelId: panelId
                )
            },
            processScopeFingerprintProvider: { [] },
            hookStoreDirectoryProvider: { directory.path }
        )
        let coordinator = TerminationResumeIndexCoordinator()

        let prepared = await coordinator.prepareForUpdateRelaunch(coordinatedBy: sharedIndex)
        let confirmed = await coordinator.loadForConfirmedTerminationAttempt(coordinatedBy: sharedIndex)

        #expect(Self.checkpoint(in: prepared, workspaceId: workspaceId, panelId: panelId) == "updater-prepared")
        #expect(Self.checkpoint(in: confirmed, workspaceId: workspaceId, panelId: panelId) == "updater-prepared")
        #expect(
            loadCount.withLock { $0 } == 1,
            "Confirmed update termination must not rescan after the terminal runtime has stopped."
        )
    }

    @Test
    func cancelledOrdinaryQuitPreservesUpdaterRelaunchPreparation() async throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        defer { AppDelegate.shared = previousAppDelegate }
        let workspaceId = UUID()
        let panelId = UUID()
        let directory = try Self.temporaryDirectory(named: "updater-preparation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                Self.loadResult(
                    checkpointId: "updater-prepared",
                    workspaceId: workspaceId,
                    panelId: panelId
                )
            },
            processScopeFingerprintProvider: { [] },
            hookStoreDirectoryProvider: { directory.path }
        )

        _ = await app.terminationResumeIndexCoordinator.load(coordinatedBy: sharedIndex)
        #expect(
            Self.checkpoint(
                in: app.terminationResumeIndexCoordinator.current(),
                workspaceId: workspaceId,
                panelId: panelId
            ) == "updater-prepared"
        )

        app.replyToTerminateOnce(false)

        #expect(
            Self.checkpoint(
                in: app.terminationResumeIndexCoordinator.current(),
                workspaceId: workspaceId,
                panelId: panelId
            ) == "updater-prepared",
            "Cancelling an unrelated quit must not abandon the updater-owned relaunch preparation."
        )
    }

    @Test
    func invalidationClearsCompletedAuthority() async throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let directory = try Self.temporaryDirectory(named: "completed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstResult = Self.loadResult(
            checkpointId: "completed",
            workspaceId: workspaceId,
            panelId: panelId
        )
        let secondResult = Self.loadResult(
            checkpointId: "fresh",
            workspaceId: workspaceId,
            panelId: panelId
        )
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                return invocation == 1 ? firstResult : secondResult
            },
            processScopeFingerprintProvider: { [] },
            hookStoreDirectoryProvider: { directory.path }
        )
        let coordinator = TerminationResumeIndexCoordinator()

        let completed = await coordinator.load(coordinatedBy: sharedIndex)
        #expect(Self.checkpoint(in: completed, workspaceId: workspaceId, panelId: panelId) == "completed")
        guard case .completed = coordinator.resolution() else {
            Issue.record("completed capture did not become authoritative")
            return
        }

        coordinator.invalidate()

        guard case .pending = coordinator.resolution() else {
            Issue.record("abandoned capture remained authoritative")
            return
        }
        #expect(coordinator.current() == nil)

        let fresh = await coordinator.load(coordinatedBy: sharedIndex)
        #expect(Self.checkpoint(in: fresh, workspaceId: workspaceId, panelId: panelId) == "fresh")
        #expect(loadCount.withLock { $0 } == 2)
    }

    @Test
    func supersededPendingLoadCannotRepublishAfterNewAttempt() async throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let oldDirectory = try Self.temporaryDirectory(named: "old")
        let newDirectory = try Self.temporaryDirectory(named: "new")
        defer {
            try? FileManager.default.removeItem(at: oldDirectory)
            try? FileManager.default.removeItem(at: newDirectory)
        }
        let oldStarted = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        let newStarted = DispatchSemaphore(value: 0)
        let releaseNew = DispatchSemaphore(value: 0)
        defer {
            releaseOld.signal()
            releaseNew.signal()
        }
        let oldIndex = Self.makeSharedIndex(
            checkpointId: "old",
            workspaceId: workspaceId,
            panelId: panelId,
            hookDirectory: oldDirectory,
            started: oldStarted,
            release: releaseOld
        )
        let newIndex = Self.makeSharedIndex(
            checkpointId: "new",
            workspaceId: workspaceId,
            panelId: panelId,
            hookDirectory: newDirectory,
            started: newStarted,
            release: releaseNew
        )
        let coordinator = TerminationResumeIndexCoordinator()

        let oldLoad = Task { @MainActor in
            await coordinator.load(coordinatedBy: oldIndex)
        }
        #expect(await Self.wait(for: oldStarted))

        let newLoad = Task { @MainActor in
            await coordinator.loadForNewTerminationAttempt(coordinatedBy: newIndex)
        }
        #expect(await Self.wait(for: newStarted))

        releaseOld.signal()
        let oldResult = await oldLoad.value
        #expect(
            oldResult == nil,
            "A superseded capture must not escape while its replacement is still pending."
        )
        #expect(coordinator.current() == nil)

        releaseNew.signal()
        let newResult = await newLoad.value
        #expect(Self.checkpoint(in: newResult, workspaceId: workspaceId, panelId: panelId) == "new")
        #expect(Self.checkpoint(in: coordinator.current(), workspaceId: workspaceId, panelId: panelId) == "new")
    }

    private static func makeSharedIndex(
        checkpointId: String,
        workspaceId: UUID,
        panelId: UUID,
        hookDirectory: URL,
        started: DispatchSemaphore? = nil,
        release: DispatchSemaphore? = nil
    ) -> SharedLiveAgentIndex {
        let result = loadResult(
            checkpointId: checkpointId,
            workspaceId: workspaceId,
            panelId: panelId
        )
        return SharedLiveAgentIndex(
            indexLoader: {
                started?.signal()
                release?.wait()
                return result
            },
            processScopeFingerprintProvider: { [] },
            hookStoreDirectoryProvider: { hookDirectory.path }
        )
    }

    nonisolated private static func loadResult(
        checkpointId: String,
        workspaceId: UUID,
        panelId: UUID
    ) -> SharedLiveAgentIndexLoader.LoadResult {
        (
            index: .empty,
            surfaceResumeBindingIndex: SurfaceResumeBindingIndex(bindingsByPanel: [
                SurfaceResumeBindingIndex.PanelKey(
                    workspaceId: workspaceId,
                    panelId: panelId
                ): SurfaceResumeBindingSnapshot(
                    name: "tmux",
                    kind: "tmux",
                    command: "tmux attach -t \(checkpointId)",
                    cwd: "/tmp/\(checkpointId)",
                    checkpointId: checkpointId,
                    source: "process-detected",
                    updatedAt: 1
                ),
            ]),
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: [],
            forkValidatedPanels: []
        )
    }

    private static func checkpoint(
        in indexes: ProcessDetectedResumeIndexes?,
        workspaceId: UUID,
        panelId: UUID
    ) -> String? {
        indexes?.surfaceResumeBindingIndex.binding(
            workspaceId: workspaceId,
            panelId: panelId
        )?.checkpointId
    }

    private static func temporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-termination-resume-index-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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
