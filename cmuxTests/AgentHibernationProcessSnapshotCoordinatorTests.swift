import Darwin
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentHibernationProcessSnapshotCoordinatorTests {
    @Test
    func coalescesOneQueuedRefreshEpoch() async throws {
        let captureScheduled = AsyncStream<Void>.makeStream()
        let allowCapture = AsyncStream<Void>.makeStream()
        let captureCount = OSAllocatedUnfairLock(initialState: 0)
        let snapshot = CmuxTopProcessSnapshot(
            processes: [],
            sampledAt: .now,
            includesProcessDetails: false
        )
        let coordinator = AgentHibernationProcessSnapshotCoordinator(
            beforeCapture: {
                captureScheduled.continuation.yield()
                for await _ in allowCapture.stream { return }
            },
            captureSnapshot: {
                captureCount.withLock { $0 += 1 }
                return snapshot
            }
        )
        let first = Task { await coordinator.nextSnapshot() }
        var captureScheduledIterator = captureScheduled.stream.makeAsyncIterator()
        _ = await captureScheduledIterator.next()
        let second = Task { await coordinator.nextSnapshot() }
        let clock = ContinuousClock()
        let registrationDeadline = clock.now.advanced(by: .seconds(1))
        while clock.now < registrationDeadline {
            if await coordinator.queuedSnapshotWaiterCount == 2 {
                break
            }
            await Task.yield()
        }
        #expect(await coordinator.queuedSnapshotWaiterCount == 2)

        allowCapture.continuation.yield()
        allowCapture.continuation.finish()
        let firstSnapshot = try #require(await first.value)
        let secondSnapshot = try #require(await second.value)

        #expect(firstSnapshot === snapshot)
        #expect(secondSnapshot === snapshot)
        #expect(captureCount.withLock { $0 } == 1)
        captureScheduled.continuation.finish()
    }

    @Test
    func cancelledWaiterDoesNotAwaitOrDuplicateCapture() async throws {
        let captureScheduled = AsyncStream<Void>.makeStream()
        let allowCapture = AsyncStream<Void>.makeStream()
        let captureCount = OSAllocatedUnfairLock(initialState: 0)
        let snapshot = CmuxTopProcessSnapshot(
            processes: [],
            sampledAt: .now,
            includesProcessDetails: false
        )
        let coordinator = AgentHibernationProcessSnapshotCoordinator(
            beforeCapture: {
                captureScheduled.continuation.yield()
                for await _ in allowCapture.stream { return }
            },
            captureSnapshot: {
                captureCount.withLock { $0 += 1 }
                return snapshot
            }
        )
        let cancelledRequest = Task { await coordinator.nextSnapshot() }
        var captureScheduledIterator = captureScheduled.stream.makeAsyncIterator()
        _ = await captureScheduledIterator.next()

        cancelledRequest.cancel()
        #expect(await cancelledRequest.value == nil)
        #expect(captureCount.withLock { $0 } == 0)

        allowCapture.continuation.yield()
        allowCapture.continuation.finish()
        let nextSnapshot = try #require(await coordinator.nextSnapshot())

        #expect(nextSnapshot === snapshot)
        #expect(captureCount.withLock { $0 } == 1)
        captureScheduled.continuation.finish()
    }

    @Test
    func rejectsLateFanoutBeforePerCandidateProbes() async {
        let scopeKey = AgentHibernationPanelKey(
            workspaceId: UUID(),
            panelId: UUID()
        )
        let ttyDevice = Int64(123)
        let processGroupID = 101
        let processes = (101...133).map { processID in
            CmuxTopProcessInfo(
                pid: processID,
                parentPID: 1,
                name: "test",
                path: nil,
                ttyDevice: ttyDevice,
                cmuxWorkspaceID: nil,
                cmuxSurfaceID: nil,
                cmuxAttributionReason: nil,
                processGroupID: processGroupID,
                terminalProcessGroupID: processGroupID,
                cpuPercent: 0,
                residentBytes: 0,
                virtualBytes: 0,
                threadCount: 1
            )
        }
        let snapshot = CmuxTopProcessSnapshot(
            processes: processes,
            sampledAt: .now,
            includesProcessDetails: false,
            includesCMUXScope: false
        )
        let leaderIdentity = AgentPIDProcessIdentity(
            pid: pid_t(processGroupID),
            startSeconds: 10,
            startMicroseconds: 1
        )
        let identityProbeIDs = OSAllocatedUnfairLock(initialState: [pid_t]())
        let argumentProbeCount = OSAllocatedUnfairLock(initialState: 0)
        let processGroupProbeCount = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = AgentHibernationProcessSnapshotCoordinator(
            captureSnapshot: { snapshot },
            processArgumentsProvider: { _ in
                argumentProbeCount.withLock { $0 += 1 }
                return nil
            },
            processIdentityProvider: { processID in
                identityProbeIDs.withLock { $0.append(processID) }
                return processID == pid_t(processGroupID) ? leaderIdentity : nil
            },
            processGroupProvider: { _ in
                processGroupProbeCount.withLock { $0 += 1 }
                return pid_t(processGroupID)
            }
        )

        let epoch = await coordinator.refreshedExitEpoch(
            processGroupLeaders: [pid_t(processGroupID): leaderIdentity],
            processScopeKey: scopeKey,
            ttyDevice: ttyDevice,
            excluding: []
        )

        #expect(epoch == nil)
        #expect(identityProbeIDs.withLock { $0 } == [pid_t(processGroupID)])
        #expect(argumentProbeCount.withLock { $0 } == 0)
        #expect(processGroupProbeCount.withLock { $0 } == 0)
    }
}
