import CmuxFoundation
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
                processIdentity: AgentPIDProcessIdentity(
                    pid: pid_t(processID), startSeconds: Int64(processID), startMicroseconds: 1
                ),
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
    @Test func reusedDescendantDoesNotJoinTheSignalableEpoch() async {
        let leader = AgentPIDProcessIdentity(pid: 101, startSeconds: 10, startMicroseconds: 1)
        let original = AgentPIDProcessIdentity(pid: 102, startSeconds: 11, startMicroseconds: 1)
        let replacement = AgentPIDProcessIdentity(pid: 102, startSeconds: 12, startMicroseconds: 1)
        let snapshot = CmuxTopProcessSnapshot(
            processes: [leader, original].map { identity in
                CmuxTopProcessInfo(
                    pid: Int(identity.pid), processIdentity: identity, parentPID: 101,
                    name: "fixture", path: nil, ttyDevice: 42, cmuxWorkspaceID: nil,
                    cmuxSurfaceID: nil, cmuxAttributionReason: nil, processGroupID: 101,
                    terminalProcessGroupID: 101, cpuPercent: 0, residentBytes: 0,
                    virtualBytes: 0, threadCount: 0
                )
            },
            sampledAt: .now, includesProcessDetails: false
        )
        let coordinator = AgentHibernationProcessSnapshotCoordinator(
            captureSnapshot: { snapshot },
            processIdentityProvider: { $0 == 101 ? leader : replacement },
            processGroupProvider: { _ in 101 }
        )
        let epoch = await coordinator.refreshedExitEpoch(
            processGroupLeaders: [101: leader], processScopeKey: nil,
            ttyDevice: 42, excluding: []
        )
        #expect(epoch == nil)
    }

    /// A Claude inbox helper still alive after the agent exited keeps its
    /// helper scope in the refreshed epoch: it is detached, so it has no
    /// terminal to match on the escalation or retry path.
    @Test(arguments: [
        ["/Applications/cmux.app/Contents/Resources/bin/cmux", "hooks", "claude", "inbox-wait"],
        ["/usr/bin/python3", "-m", "http.server"],
    ])
    func refreshedEpochKeepsOnlyARegisteredHelperDetached(arguments: [String]) async throws {
        let scopeKey = AgentHibernationPanelKey(workspaceId: UUID(), panelId: UUID())
        let helper = AgentPIDProcessIdentity(pid: 202, startSeconds: 20, startMicroseconds: 2)
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: 202, processIdentity: helper, parentPID: 1,
                    name: "cmux", path: nil, ttyDevice: nil, cmuxWorkspaceID: nil,
                    cmuxSurfaceID: nil, cmuxAttributionReason: nil, processGroupID: 202,
                    terminalProcessGroupID: nil, cpuPercent: 0, residentBytes: 0,
                    virtualBytes: 0, threadCount: 0
                ),
            ],
            sampledAt: .now, includesProcessDetails: false, includesCMUXScope: false
        )
        let coordinator = AgentHibernationProcessSnapshotCoordinator(
            captureSnapshot: { snapshot },
            processArgumentsProvider: { _ in
                CmuxTopProcessArguments(
                    arguments: arguments,
                    environment: [
                        "CMUX_WORKSPACE_ID": scopeKey.workspaceId.uuidString,
                        "CMUX_SURFACE_ID": scopeKey.panelId.uuidString,
                    ]
                )
            },
            processIdentityProvider: { _ in helper },
            processGroupProvider: { _ in 202 }
        )

        let epoch = try #require(await coordinator.refreshedExitEpoch(
            processGroupLeaders: [202: helper], processScopeKey: scopeKey,
            ttyDevice: 42, excluding: []
        ))

        let isRegistered = arguments.dropFirst() == ["hooks", "claude", "inbox-wait"]
        #expect(epoch.terminations == [
            .init(
                processID: 202, processIdentity: helper, processGroupID: 202,
                ttyDevice: nil, isCmuxHelper: isRegistered
            ),
        ])
        #expect(epoch.signalableProcessIdentities == [helper])
    }
}
