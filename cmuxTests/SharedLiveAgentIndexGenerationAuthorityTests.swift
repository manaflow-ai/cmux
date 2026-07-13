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
@Suite("Shared live-agent generation authority", .serialized)
struct SharedLiveAgentIndexGenerationAuthorityTests {
    @Test
    func timedOutValidatorCannotInvalidateCompletedSuccessor() async throws {
        let timeoutWaiter = ManualGenerationTimeoutWaiter()
        let fingerprintStarted = DispatchSemaphore(value: 0)
        let releaseFingerprint = DispatchSemaphore(value: 0)
        let successorLoadStarted = DispatchSemaphore(value: 0)
        defer { releaseFingerprint.signal() }
        // Synchronous loader callbacks can overlap; the lock protects only this test counter.
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let workspaceId = UUID()
        let panelId = UUID()
        let now = Date()
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-generation-authority-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let staleResult: SharedLiveAgentIndex.LoadResult = (
            index: SharedLiveAgentIndexLoadCoalescingTests.index(
                workspaceId: workspaceId,
                panelId: panelId,
                sessionId: "stale-session"
            ),
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: ["scope-a"],
            forkValidatedPanels: []
        )
        let successorResult: SharedLiveAgentIndex.LoadResult = (
            index: SharedLiveAgentIndexLoadCoalescingTests.index(
                workspaceId: workspaceId,
                panelId: panelId,
                sessionId: "successor-session"
            ),
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: ["scope-b"],
            forkValidatedPanels: []
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadCount.withLock { $0 += 1 }
                successorLoadStarted.signal()
                return successorResult
            },
            processScopeFingerprintProvider: {
                fingerprintStarted.signal()
                releaseFingerprint.wait()
                return ["scope-b"]
            },
            generationTimeoutWaiter: { await timeoutWaiter.wait() },
            hookStoreDirectoryProvider: { hookDirectory.path },
            dateProvider: { now }
        )
        sharedIndex.applyReloadedResult(
            staleResult,
            validationPanelsByPanelID: [:],
            generationID: UUID()
        )
        sharedIndex.latestCompletedLoadResult = staleResult
        sharedIndex.latestCompletedAt = now

        let staleRead = Task { @MainActor in
            await sharedIndex.resumeIndexesRefreshingIfNeeded(maximumAge: 60)
        }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: fingerprintStarted))
        await timeoutWaiter.waitUntilPendingCount(1)
        let timedOutGenerationID = try #require(sharedIndex.refreshTailID)
        let timedOutWorkTask = try #require(
            sharedIndex.refreshWorkTasksByID[timedOutGenerationID]
        )
        await timeoutWaiter.fireNext()
        #expect(await staleRead.value == nil)

        let successor = Task { @MainActor in
            await sharedIndex.resumeIndexesCapturedAfterRequest()
        }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: successorLoadStarted))
        let successorValue = await successor.value
        _ = try #require(successorValue)
        #expect(Self.sessionId(in: sharedIndex.cachedResumeIndexes(), workspaceId: workspaceId, panelId: panelId)
            == "successor-session")

        releaseFingerprint.signal()
        await timedOutWorkTask.value
        #expect(loadCount.withLock { $0 } == 1)
        #expect(
            Self.sessionId(in: sharedIndex.cachedResumeIndexes(), workspaceId: workspaceId, panelId: panelId)
                == "successor-session",
            "A timed-out validator must not revoke a newer generation's authority."
        )
        await timeoutWaiter.cancelAll()
    }

    @Test
    func timedOutFingerprintValidationDoesNotStartFullLoadOrRetainCapacity() async throws {
        let timeoutWaiter = ManualGenerationTimeoutWaiter()
        let fingerprintStarted = DispatchSemaphore(value: 0)
        let releaseFingerprint = DispatchSemaphore(value: 0)
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        defer { releaseFingerprint.signal() }
        let now = Date()
        let hookDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-timed-out-validation-work-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookDirectory) }
        let cachedResult: SharedLiveAgentIndex.LoadResult = (
            index: .empty,
            surfaceResumeBindingIndex: .empty,
            liveAgentProcessFingerprint: [],
            processScopeFingerprint: ["scope"],
            forkValidatedPanels: []
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadCount.withLock { $0 += 1 }
                return cachedResult
            },
            processScopeFingerprintProvider: {
                fingerprintStarted.signal()
                releaseFingerprint.wait()
                return ["scope"]
            },
            generationTimeoutWaiter: { await timeoutWaiter.wait() },
            hookStoreDirectoryProvider: { hookDirectory.path },
            dateProvider: { now }
        )
        sharedIndex.latestCompletedLoadResult = cachedResult
        sharedIndex.latestCompletedAt = now

        let read = Task { @MainActor in
            await sharedIndex.resumeIndexesRefreshingIfNeeded(maximumAge: 60)
        }
        #expect(await SharedLiveAgentIndexLoadCoalescingTests.wait(for: fingerprintStarted))
        await timeoutWaiter.waitUntilPendingCount(1)
        let generationID = try #require(sharedIndex.refreshTailID)
        let workTask = try #require(sharedIndex.refreshWorkTasksByID[generationID])
        await timeoutWaiter.fireNext()
        #expect(await read.value == nil)

        releaseFingerprint.signal()
        await workTask.value

        #expect(loadCount.withLock { $0 } == 0)
        #expect(sharedIndex.refreshGenerationsByID[generationID] == nil)
        #expect(!sharedIndex.capturingGenerationIDs.contains(generationID))
        #expect(sharedIndex.refreshTailID == nil)
    }

    private static func sessionId(
        in indexes: ProcessDetectedResumeIndexes?,
        workspaceId: UUID,
        panelId: UUID
    ) -> String? {
        indexes?.restorableAgentIndex.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId
    }
}
