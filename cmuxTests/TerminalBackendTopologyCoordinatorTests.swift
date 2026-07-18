import AppKit
import Bonsplit
import CmuxTerminal
import CmuxTerminalBackend
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal backend topology coordinator", .serialized)
struct TerminalBackendTopologyCoordinatorTests {
    @Test @MainActor
    func daemonActivityProjectsUnreadByCanonicalSurfaceAndReceipt() async throws {
        let authority = makeAuthority()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let readerID = UUID()
        let topologyPair = AsyncStream<TerminalBackendTopologyStreamEvent>.makeStream()
        let activityPair = AsyncStream<BackendTerminalActivitySnapshot>.makeStream()
        var reported: [Set<UUID>] = []
        let coordinator = TerminalBackendTopologyCoordinator(
            eventSource: { topologyPair.stream },
            projector: RecordingTopologyProjector(),
            authorizationGate: TerminalBackendTopologyAuthorizationGate(),
            activitySource: { activityPair.stream },
            activityReporter: { reported.append($0) }
        )

        coordinator.startupRestoreDidFinish()
        coordinator.start()
        topologyPair.continuation.yield(.snapshot(try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: workspaceID,
                surfaceIDs: [surfaceID]
            )]
        )))
        let fact = BackendTerminalActivityFact(
            surfaceID: SurfaceID(rawValue: surfaceID),
            sequence: 1,
            kind: .notification,
            notificationID: 7,
            level: .info
        )
        activityPair.continuation.yield(BackendTerminalActivitySnapshot(
            readerUUID: readerID,
            latestSequence: 1,
            facts: [fact],
            receipts: []
        ))
        await settle()
        #expect(reported.last == [workspaceID])

        activityPair.continuation.yield(BackendTerminalActivitySnapshot(
            readerUUID: readerID,
            latestSequence: 1,
            facts: [fact],
            receipts: [BackendTerminalActivityReceipt(
                readerUUID: readerID,
                surfaceID: SurfaceID(rawValue: surfaceID),
                seenSequence: 1
            )]
        ))
        await settle()
        #expect(reported.last == [])
    }

    @Test @MainActor
    func rejectsStaleSnapshotsAndConvergesAfterDaemonRestart() async throws {
        let authority = makeAuthority()
        let replacementAuthority = makeAuthority(sessionID: authority.sessionID)
        let surfaceID = UUID()
        let projector = RecordingTopologyProjector()
        let gate = TerminalBackendTopologyAuthorizationGate()
        let pair = AsyncStream<TopologySnapshot>.makeStream()
        let coordinator = TerminalBackendTopologyCoordinator(
            snapshotSource: { pair.stream },
            projector: projector,
            authorizationGate: gate
        )

        coordinator.startupRestoreDidFinish()
        coordinator.start()
        pair.continuation.yield(try makeSnapshot(
            authority: authority,
            revision: 8,
            workspaces: [makeWorkspace(surfaceIDs: [surfaceID])]
        ))
        pair.continuation.yield(try makeSnapshot(
            authority: authority,
            revision: 7,
            workspaces: [makeWorkspace(surfaceIDs: [UUID()])]
        ))
        pair.continuation.yield(try makeSnapshot(
            authority: replacementAuthority,
            revision: 1,
            workspaces: [makeWorkspace(surfaceIDs: [surfaceID])]
        ))
        await settle()

        #expect(projector.installedSnapshots.map(\.revision) == [8, 1])
        #expect(coordinator.debugInstalledRevision == 1)
    }

    @Test @MainActor
    func nonemptyDaemonSnapshotWinsAfterStartupRestoreWithoutLegacyImport() async throws {
        let surfaceID = UUID()
        let projector = RecordingTopologyProjector(
            legacyPlacements: [TerminalBackendTopologyPlacement(
                workspaceID: UUID(),
                surfaceID: UUID()
            )]
        )
        let gate = TerminalBackendTopologyAuthorizationGate()
        let pair = AsyncStream<TopologySnapshot>.makeStream()
        let coordinator = TerminalBackendTopologyCoordinator(
            snapshotSource: { pair.stream },
            projector: projector,
            authorizationGate: gate
        )

        coordinator.start()
        pair.continuation.yield(try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [makeWorkspace(surfaceIDs: [surfaceID])]
        ))
        await settle()
        #expect(projector.installedSnapshots.isEmpty)

        coordinator.startupRestoreDidFinish()
        await settle()

        #expect(projector.installedSnapshots.map(\.revision) == [1])
        #expect(projector.legacyReadCount == 0)
    }

    @Test @MainActor
    func emptyDaemonImportsLegacyPlacementsOnlyOnceBeforeProjection() async throws {
        let authority = makeAuthority()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let placement = TerminalBackendTopologyPlacement(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        let projector = RecordingTopologyProjector(legacyPlacements: [placement])
        let gate = TerminalBackendTopologyAuthorizationGate()
        let pair = AsyncStream<TopologySnapshot>.makeStream()
        let coordinator = TerminalBackendTopologyCoordinator(
            snapshotSource: { pair.stream },
            projector: projector,
            authorizationGate: gate
        )

        coordinator.start()
        pair.continuation.yield(try makeSnapshot(authority: authority, revision: 1, workspaces: []))
        await settle()
        #expect(projector.installedSnapshots.isEmpty)
        #expect(projector.legacyReadCount == 0)

        coordinator.startupRestoreDidFinish()
        await settle()
        #expect(projector.legacyReadCount == 1)
        #expect(coordinator.debugExpectedLegacyPlacements == [placement])
        try await gate.waitUntilAuthorized(placement)

        pair.continuation.yield(try makeSnapshot(
            authority: authority,
            revision: 2,
            workspaces: [makeWorkspace(workspaceID: workspaceID, surfaceIDs: [surfaceID])]
        ))
        pair.continuation.yield(try makeSnapshot(
            authority: authority,
            revision: 3,
            workspaces: [makeWorkspace(workspaceID: workspaceID, surfaceIDs: [surfaceID])]
        ))
        await settle()

        #expect(projector.legacyReadCount == 1)
        #expect(projector.installedSnapshots.map(\.revision) == [2, 3])
        #expect(coordinator.debugExpectedLegacyPlacements == nil)
    }

    @Test @MainActor
    func multipleScreensKeepLaterScreensDormantAndUnauthorized() async throws {
        let projector = RecordingTopologyProjector()
        let gate = TerminalBackendTopologyAuthorizationGate()
        let pair = AsyncStream<TopologySnapshot>.makeStream()
        var failure: String?
        let coordinator = TerminalBackendTopologyCoordinator(
            snapshotSource: { pair.stream },
            projector: projector,
            authorizationGate: gate,
            failureReporter: { failure = $0 }
        )
        let workspaceID = UUID()
        let presentedSurfaceID = UUID()
        let dormantSurfaceID = UUID()
        let screens = [
            makeScreen(surfaceIDs: [presentedSurfaceID]),
            makeScreen(
                surfaceIDs: [dormantSurfaceID],
                screenNumber: 2,
                paneNumber: 2,
                firstSurfaceNumber: 2
            ),
        ]

        coordinator.start()
        pair.continuation.yield(try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [CanonicalWorkspace(
                id: 1,
                uuid: WorkspaceID(rawValue: workspaceID),
                name: "unsupported",
                screens: screens
            )]
        ))
        await settle()

        #expect(projector.installedSnapshots.map(\.revision) == [1])
        #expect(failure == nil)
        #expect(projector.installedPlans.last?.placements == [
            TerminalBackendTopologyPlacement(
                workspaceID: workspaceID,
                surfaceID: presentedSurfaceID
            ),
        ])
        #expect(!(await gate.isAuthorized(TerminalBackendTopologyPlacement(
            workspaceID: workspaceID,
            surfaceID: dormantSurfaceID
        ))))

        pair.continuation.yield(try makeSnapshot(
            authority: makeAuthority(),
            revision: 2,
            workspaces: [makeWorkspace(surfaceIDs: [UUID()])]
        ))
        await settle()

        #expect(projector.installedSnapshots.map(\.revision) == [1, 2])
        #expect(failure == nil)
    }

    @Test @MainActor
    func disconnectRevokesAuthorityAndFreshSnapshotResumesProjection() async throws {
        let firstAuthority = makeAuthority()
        let secondAuthority = makeAuthority(sessionID: firstAuthority.sessionID)
        let workspaceID = UUID()
        let surfaceID = UUID()
        let placement = TerminalBackendTopologyPlacement(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        let projector = RecordingTopologyProjector()
        let gate = TerminalBackendTopologyAuthorizationGate()
        let pair = AsyncStream<TerminalBackendTopologyStreamEvent>.makeStream()
        let coordinator = TerminalBackendTopologyCoordinator(
            eventSource: { pair.stream },
            projector: projector,
            authorizationGate: gate
        )

        coordinator.startupRestoreDidFinish()
        coordinator.start()
        pair.continuation.yield(.snapshot(try makeSnapshot(
            authority: firstAuthority,
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: workspaceID,
                surfaceIDs: [surfaceID]
            )]
        )))
        await settle()
        let initiallyAuthorized = await gate.isAuthorized(placement)
        #expect(initiallyAuthorized)

        pair.continuation.yield(.disconnected(firstAuthority))
        await settle()
        let authorizedWhileDisconnected = await gate.isAuthorized(placement)
        #expect(!authorizedWhileDisconnected)

        pair.continuation.yield(.snapshot(try makeSnapshot(
            authority: secondAuthority,
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: workspaceID,
                surfaceIDs: [surfaceID]
            )]
        )))
        await settle()

        #expect(projector.installedSnapshots.map(\.authority) == [firstAuthority, secondAuthority])
        let reauthorized = await gate.isAuthorized(placement)
        #expect(reauthorized)
    }

    @Test @MainActor
    func disconnectRevokesAuthoritylessLegacyImportAdmission() async throws {
        let authority = makeAuthority()
        let placement = TerminalBackendTopologyPlacement(
            workspaceID: UUID(),
            surfaceID: UUID()
        )
        let projector = RecordingTopologyProjector(legacyPlacements: [placement])
        let gate = TerminalBackendTopologyAuthorizationGate()
        let pair = AsyncStream<TerminalBackendTopologyStreamEvent>.makeStream()
        let coordinator = TerminalBackendTopologyCoordinator(
            eventSource: { pair.stream },
            projector: projector,
            authorizationGate: gate
        )

        coordinator.startupRestoreDidFinish()
        coordinator.start()
        pair.continuation.yield(.snapshot(try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: []
        )))
        await settle()
        let authorizedBeforeDisconnect = await gate.isAuthorized(placement)
        #expect(authorizedBeforeDisconnect)

        pair.continuation.yield(.disconnected(authority))
        await settle()

        let authorizedAfterDisconnect = await gate.isAuthorized(placement)
        #expect(!authorizedAfterDisconnect)
    }

    @Test
    func staleSameAuthorityRevokeCannotClearNewerAuthorization() async {
        let authority = makeAuthority()
        let olderPlacement = TerminalBackendTopologyPlacement(
            workspaceID: UUID(),
            surfaceID: UUID()
        )
        let newerPlacement = TerminalBackendTopologyPlacement(
            workspaceID: UUID(),
            surfaceID: UUID()
        )
        let gate = TerminalBackendTopologyAuthorizationGate()

        await gate.authorize(
            authority: authority,
            revision: 2,
            placements: [newerPlacement]
        )
        await gate.revoke(authority: authority, revision: 1)

        #expect(await gate.isAuthorized(newerPlacement))
        #expect(!(await gate.isAuthorized(olderPlacement)))

        await gate.revoke(authority: authority, revision: 2)
        #expect(!(await gate.isAuthorized(newerPlacement)))
    }

    @Test
    func staleSameRevisionTokenRevokeCannotClearReprojectedAuthorization() async {
        let authority = makeAuthority()
        let placement = TerminalBackendTopologyPlacement(
            workspaceID: UUID(),
            surfaceID: UUID()
        )
        let gate = TerminalBackendTopologyAuthorizationGate()

        let staleToken = await gate.authorize(
            authority: authority,
            revision: 4,
            placements: [placement]
        )
        let currentToken = await gate.authorize(
            authority: authority,
            revision: 4,
            placements: [placement]
        )

        await gate.revoke(
            authority: authority,
            revision: 4,
            token: staleToken
        )
        #expect(await gate.isAuthorized(placement))

        await gate.revoke(
            authority: authority,
            revision: 4,
            token: currentToken
        )
        #expect(!(await gate.isAuthorized(placement)))
    }

    @Test
    func staleLegacyTokenRevokeCannotClearNewLegacyAuthorization() async {
        let stalePlacement = TerminalBackendTopologyPlacement(
            workspaceID: UUID(),
            surfaceID: UUID()
        )
        let currentPlacement = TerminalBackendTopologyPlacement(
            workspaceID: UUID(),
            surfaceID: UUID()
        )
        let gate = TerminalBackendTopologyAuthorizationGate()

        let staleToken = await gate.authorize([stalePlacement])
        let currentToken = await gate.authorize([currentPlacement])
        await gate.revokeLegacyAuthorization(token: staleToken)

        #expect(!(await gate.isAuthorized(stalePlacement)))
        #expect(await gate.isAuthorized(currentPlacement))

        await gate.revokeLegacyAuthorization(token: currentToken)
        #expect(!(await gate.isAuthorized(currentPlacement)))
    }

    @Test
    func admissionEpochRejectsStaleCanonicalAndLegacyInstallation() async throws {
        let authority = makeAuthority()
        let canonicalPlacement = TerminalBackendTopologyPlacement(
            workspaceID: UUID(),
            surfaceID: UUID()
        )
        let legacyPlacement = TerminalBackendTopologyPlacement(
            workspaceID: UUID(),
            surfaceID: UUID()
        )
        let gate = TerminalBackendTopologyAuthorizationGate()
        let staleEpoch = gate.currentAdmissionEpoch

        let initialToken = await gate.authorize(
            authority: authority,
            revision: 1,
            placements: [canonicalPlacement],
            admissionEpoch: staleEpoch
        )
        #expect(initialToken != nil)
        #expect(await gate.isAuthorized(canonicalPlacement))
        let staleLease = try await gate.waitUntilAuthorized(canonicalPlacement)

        let currentEpoch = gate.advanceAdmissionEpoch()
        #expect(currentEpoch != staleEpoch)
        #expect(!(await gate.isAuthorized(canonicalPlacement)))
        await #expect(throws: TerminalBackendTopologyAdmissionError.invalidated) {
            try await gate.validate(staleLease)
        }
        #expect(await gate.authorize(
            authority: authority,
            revision: 1,
            placements: [canonicalPlacement],
            admissionEpoch: staleEpoch
        ) == nil)
        #expect(await gate.authorize(
            [legacyPlacement],
            admissionEpoch: staleEpoch
        ) == nil)

        #expect(await gate.authorize(
            authority: authority,
            revision: 1,
            placements: [canonicalPlacement],
            admissionEpoch: currentEpoch
        ) != nil)
        #expect(await gate.isAuthorized(canonicalPlacement))
        let replacedLease = try await gate.waitUntilAuthorized(canonicalPlacement)
        #expect(await gate.authorize(
            authority: authority,
            revision: 1,
            placements: [canonicalPlacement],
            admissionEpoch: currentEpoch
        ) != nil)
        await #expect(throws: TerminalBackendTopologyAdmissionError.invalidated) {
            try await gate.validate(replacedLease)
        }
    }

    @Test @MainActor
    func projectorChangeInvalidatesSameRevisionBeforeReprojection() async throws {
        let authority = makeAuthority()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let placement = TerminalBackendTopologyPlacement(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        let planner = SuspendAfterFirstTopologyPlanBuilder()
        let projector = RecordingTopologyProjector()
        let gate = TerminalBackendTopologyAuthorizationGate()
        let pair = AsyncStream<TopologySnapshot>.makeStream()
        let coordinator = TerminalBackendTopologyCoordinator(
            snapshotSource: { pair.stream },
            projector: projector,
            authorizationGate: gate,
            planBuilder: { topology in try await planner.build(topology) }
        )

        coordinator.startupRestoreDidFinish()
        coordinator.start()
        pair.continuation.yield(try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: workspaceID,
                surfaceIDs: [surfaceID]
            )]
        ))
        await settle()
        #expect(await gate.isAuthorized(placement))
        let installedEpoch = gate.currentAdmissionEpoch

        coordinator.projectorsDidChange()
        let reprojectionEpoch = gate.currentAdmissionEpoch
        #expect(reprojectionEpoch != installedEpoch)
        await planner.waitUntilBlocked()
        #expect(!(await gate.isAuthorized(placement)))
        #expect(await gate.authorize(
            authority: authority,
            revision: 1,
            placements: [placement],
            admissionEpoch: installedEpoch
        ) == nil)

        await planner.resume()
        await settle()
        #expect(projector.installedSnapshots.map(\.revision) == [1, 1])
        #expect(await gate.isAuthorized(placement))
    }

    @Test @MainActor
    func projectorChangeInvalidatesStaleLegacyBeforeReplacementImport() async throws {
        let authority = makeAuthority()
        let stalePlacement = TerminalBackendTopologyPlacement(
            workspaceID: UUID(),
            surfaceID: UUID()
        )
        let currentPlacement = TerminalBackendTopologyPlacement(
            workspaceID: UUID(),
            surfaceID: UUID()
        )
        let planner = SuspendAfterFirstTopologyPlanBuilder()
        let projector = RecordingTopologyProjector(legacyPlacements: [stalePlacement])
        let gate = TerminalBackendTopologyAuthorizationGate()
        let pair = AsyncStream<TopologySnapshot>.makeStream()
        let coordinator = TerminalBackendTopologyCoordinator(
            snapshotSource: { pair.stream },
            projector: projector,
            authorizationGate: gate,
            planBuilder: { topology in try await planner.build(topology) }
        )

        coordinator.startupRestoreDidFinish()
        coordinator.start()
        pair.continuation.yield(try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: []
        ))
        await settle()
        #expect(await gate.isAuthorized(stalePlacement))
        let legacyEpoch = gate.currentAdmissionEpoch

        projector.legacyPlacements = [currentPlacement]
        coordinator.projectorsDidChange()
        #expect(gate.currentAdmissionEpoch != legacyEpoch)
        await planner.waitUntilBlocked()
        #expect(!(await gate.isAuthorized(stalePlacement)))
        #expect(await gate.authorize(
            [stalePlacement],
            admissionEpoch: legacyEpoch
        ) == nil)

        await planner.resume()
        await settle()
        #expect(!(await gate.isAuthorized(stalePlacement)))
        #expect(await gate.isAuthorized(currentPlacement))
        #expect(projector.legacyReadCount == 2)
    }

    @Test @MainActor
    func failedNewRevisionRevokesPreviouslyInstalledPlacements() async throws {
        let authority = makeAuthority()
        let firstWorkspaceID = UUID()
        let firstSurfaceID = UUID()
        let secondWorkspaceID = UUID()
        let secondSurfaceID = UUID()
        let firstPlacement = TerminalBackendTopologyPlacement(
            workspaceID: firstWorkspaceID,
            surfaceID: firstSurfaceID
        )
        let projector = RecordingTopologyProjector(failCommitRevisions: [2])
        let gate = TerminalBackendTopologyAuthorizationGate()
        let pair = AsyncStream<TopologySnapshot>.makeStream()
        let coordinator = TerminalBackendTopologyCoordinator(
            snapshotSource: { pair.stream },
            projector: projector,
            authorizationGate: gate
        )

        coordinator.startupRestoreDidFinish()
        coordinator.start()
        pair.continuation.yield(try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: firstWorkspaceID,
                surfaceIDs: [firstSurfaceID]
            )]
        ))
        await settle()
        #expect(await gate.isAuthorized(firstPlacement))

        pair.continuation.yield(try makeSnapshot(
            authority: authority,
            revision: 2,
            workspaces: [makeWorkspace(
                workspaceID: secondWorkspaceID,
                surfaceIDs: [secondSurfaceID]
            )]
        ))
        await settle()

        #expect(projector.installedSnapshots.map(\.revision) == [1])
        #expect(coordinator.debugInstalledRevision == nil)
        #expect(!(await gate.isAuthorized(firstPlacement)))
        #expect(!(await gate.isAuthorized(TerminalBackendTopologyPlacement(
            workspaceID: secondWorkspaceID,
            surfaceID: secondSurfaceID
        ))))
    }

    @Test @MainActor
    func transientProjectionFailureRetriesUnchangedSnapshotOnce() async throws {
        let authority = makeAuthority()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let placement = TerminalBackendTopologyPlacement(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        let projector = RecordingTopologyProjector(
            transientCommitFailures: [1: 1]
        )
        let gate = TerminalBackendTopologyAuthorizationGate()
        let pair = AsyncStream<TopologySnapshot>.makeStream()
        let coordinator = TerminalBackendTopologyCoordinator(
            snapshotSource: { pair.stream },
            projector: projector,
            authorizationGate: gate
        )

        coordinator.startupRestoreDidFinish()
        coordinator.start()
        pair.continuation.yield(try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: workspaceID,
                surfaceIDs: [surfaceID]
            )]
        ))
        await settle()

        #expect(projector.commitAttemptRevisions == [1, 1])
        #expect(projector.installedSnapshots.map(\.revision) == [1])
        #expect(coordinator.debugInstalledRevision == 1)
        #expect(await gate.isAuthorized(placement))
    }

    @Test @MainActor
    func permanentProjectionFailureRetriesOncePerConcreteSignal() async throws {
        let authority = makeAuthority()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let projector = RecordingTopologyProjector(failCommitRevisions: [1])
        let gate = TerminalBackendTopologyAuthorizationGate()
        let pair = AsyncStream<TopologySnapshot>.makeStream()
        let coordinator = TerminalBackendTopologyCoordinator(
            snapshotSource: { pair.stream },
            projector: projector,
            authorizationGate: gate
        )

        coordinator.startupRestoreDidFinish()
        coordinator.start()
        pair.continuation.yield(try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: workspaceID,
                surfaceIDs: [surfaceID]
            )]
        ))
        await settle()
        await settle()
        #expect(projector.commitAttemptRevisions == [1, 1])
        #expect(coordinator.debugInstalledRevision == nil)

        for _ in 0..<32 { await Task.yield() }
        #expect(projector.commitAttemptRevisions == [1, 1])

        coordinator.projectorsDidChange()
        await settle()
        await settle()
        #expect(projector.commitAttemptRevisions == [1, 1, 1, 1])

        for _ in 0..<32 { await Task.yield() }
        #expect(projector.commitAttemptRevisions == [1, 1, 1, 1])
    }

    @Test @MainActor
    func newerSnapshotSupersedesPendingRollbackRetry() async throws {
        let authority = makeAuthority()
        let firstWorkspaceID = UUID()
        let firstSurfaceID = UUID()
        let secondWorkspaceID = UUID()
        let secondSurfaceID = UUID()
        let planner = SuspendSecondTopologyPlanBuilder()
        let projector = RecordingTopologyProjector(failCommitRevisions: [1])
        let gate = TerminalBackendTopologyAuthorizationGate()
        let pair = AsyncStream<TopologySnapshot>.makeStream()
        let coordinator = TerminalBackendTopologyCoordinator(
            snapshotSource: { pair.stream },
            projector: projector,
            authorizationGate: gate,
            planBuilder: { topology in try await planner.build(topology) }
        )

        coordinator.startupRestoreDidFinish()
        coordinator.start()
        pair.continuation.yield(try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: firstWorkspaceID,
                surfaceIDs: [firstSurfaceID]
            )]
        ))
        await planner.waitUntilRetryIsBlocked()

        pair.continuation.yield(try makeSnapshot(
            authority: authority,
            revision: 2,
            workspaces: [makeWorkspace(
                workspaceID: secondWorkspaceID,
                surfaceIDs: [secondSurfaceID]
            )]
        ))
        await planner.waitUntilSupersedingPlanStarts()
        await planner.resumeRetry()
        await settle()

        #expect(projector.commitAttemptRevisions == [1, 2])
        #expect(projector.installedSnapshots.map(\.revision) == [2])
        #expect(coordinator.debugInstalledRevision == 2)
        #expect(await gate.isAuthorized(TerminalBackendTopologyPlacement(
            workspaceID: secondWorkspaceID,
            surfaceID: secondSurfaceID
        )))
    }

    @Test @MainActor
    func browserOnlyDaemonTopologyNeverOpensLegacyTerminalImport() async throws {
        let legacyPlacement = TerminalBackendTopologyPlacement(
            workspaceID: UUID(),
            surfaceID: UUID()
        )
        let browserWorkspaceID = UUID()
        let browserSurfaceID = UUID()
        let browserPane = CanonicalPane(
            id: 1,
            uuid: CmuxTerminalBackend.PaneID(rawValue: UUID()),
            name: nil,
            tabs: [CanonicalSurface(
                id: 1,
                uuid: SurfaceID(rawValue: browserSurfaceID),
                kind: "browser",
                name: "browser"
            )]
        )
        let projector = RecordingTopologyProjector(legacyPlacements: [legacyPlacement])
        let gate = TerminalBackendTopologyAuthorizationGate()
        let pair = AsyncStream<TopologySnapshot>.makeStream()
        let coordinator = TerminalBackendTopologyCoordinator(
            snapshotSource: { pair.stream },
            projector: projector,
            authorizationGate: gate
        )

        coordinator.startupRestoreDidFinish()
        coordinator.start()
        pair.continuation.yield(try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [CanonicalWorkspace(
                id: 1,
                uuid: WorkspaceID(rawValue: browserWorkspaceID),
                name: "browser",
                screens: [CanonicalScreen(
                    id: 1,
                    uuid: ScreenID(rawValue: UUID()),
                    name: nil,
                    layout: .leaf(pane: browserPane.id, paneUUID: browserPane.uuid),
                    panes: [browserPane]
                )]
            )]
        ))
        await settle()

        #expect(projector.installedSnapshots.map(\.revision) == [1])
        #expect(projector.legacyReadCount == 0)
        #expect(!(await gate.isAuthorized(legacyPlacement)))
    }

    @Test @MainActor
    func suspendedStartupPlanCannotOverwriteNewerAuthority() async throws {
        let firstAuthority = makeAuthority()
        let secondAuthority = makeAuthority(sessionID: firstAuthority.sessionID)
        let firstWorkspaceID = UUID()
        let secondWorkspaceID = UUID()
        let planner = SuspendedTopologyPlanBuilder(blockedWorkspaceID: firstWorkspaceID)
        let projector = RecordingTopologyProjector()
        let gate = TerminalBackendTopologyAuthorizationGate()
        let pair = AsyncStream<TerminalBackendTopologyStreamEvent>.makeStream()
        let coordinator = TerminalBackendTopologyCoordinator(
            eventSource: { pair.stream },
            projector: projector,
            authorizationGate: gate,
            planBuilder: { topology in
                try await planner.build(topology)
            }
        )

        coordinator.start()
        pair.continuation.yield(.snapshot(try makeSnapshot(
            authority: firstAuthority,
            revision: 9,
            workspaces: [makeWorkspace(
                workspaceID: firstWorkspaceID,
                surfaceIDs: [UUID()]
            )]
        )))
        await settle()

        coordinator.startupRestoreDidFinish()
        await planner.waitUntilBlocked()
        pair.continuation.yield(.snapshot(try makeSnapshot(
            authority: secondAuthority,
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: secondWorkspaceID,
                surfaceIDs: [UUID()]
            )]
        )))
        await settle()
        await planner.resume()
        await settle()

        #expect(projector.installedSnapshots.map(\.authority) == [secondAuthority])
        #expect(coordinator.debugInstalledRevision == 1)
    }

    @Test @MainActor
    func suspendedSteadyStatePlanCannotBlockOrOverwriteNewerSnapshot() async throws {
        let authority = makeAuthority()
        let initialWorkspaceID = UUID()
        let blockedWorkspaceID = UUID()
        let newestWorkspaceID = UUID()
        let newestSurfaceID = UUID()
        let planner = SuspendedTopologyPlanBuilder(blockedWorkspaceID: blockedWorkspaceID)
        let projector = RecordingTopologyProjector()
        let gate = TerminalBackendTopologyAuthorizationGate()
        let pair = AsyncStream<TerminalBackendTopologyStreamEvent>.makeStream()
        let coordinator = TerminalBackendTopologyCoordinator(
            eventSource: { pair.stream },
            projector: projector,
            authorizationGate: gate,
            planBuilder: { topology in try await planner.build(topology) }
        )

        coordinator.startupRestoreDidFinish()
        coordinator.start()
        pair.continuation.yield(.snapshot(try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: initialWorkspaceID,
                surfaceIDs: [UUID()]
            )]
        )))
        await settle()

        pair.continuation.yield(.snapshot(try makeSnapshot(
            authority: authority,
            revision: 2,
            workspaces: [makeWorkspace(
                workspaceID: blockedWorkspaceID,
                surfaceIDs: [UUID()]
            )]
        )))
        await planner.waitUntilBlocked()
        pair.continuation.yield(.snapshot(try makeSnapshot(
            authority: authority,
            revision: 3,
            workspaces: [makeWorkspace(
                workspaceID: newestWorkspaceID,
                surfaceIDs: [newestSurfaceID]
            )]
        )))
        await settle()
        await planner.resume()
        await settle()

        #expect(projector.installedSnapshots.map(\.revision) == [1, 3])
        #expect(coordinator.debugInstalledRevision == 3)
        let newestAuthorized = await gate.isAuthorized(TerminalBackendTopologyPlacement(
            workspaceID: newestWorkspaceID,
            surfaceID: newestSurfaceID
        ))
        #expect(newestAuthorized)
    }

    @Test @MainActor
    func disconnectRevokesWhileSteadyStatePlanIsSuspended() async throws {
        let authority = makeAuthority()
        let initialWorkspaceID = UUID()
        let initialSurfaceID = UUID()
        let blockedWorkspaceID = UUID()
        let planner = SuspendedTopologyPlanBuilder(blockedWorkspaceID: blockedWorkspaceID)
        let projector = RecordingTopologyProjector()
        let gate = TerminalBackendTopologyAuthorizationGate()
        let pair = AsyncStream<TerminalBackendTopologyStreamEvent>.makeStream()
        let coordinator = TerminalBackendTopologyCoordinator(
            eventSource: { pair.stream },
            projector: projector,
            authorizationGate: gate,
            planBuilder: { topology in try await planner.build(topology) }
        )

        coordinator.startupRestoreDidFinish()
        coordinator.start()
        let initialPlacement = TerminalBackendTopologyPlacement(
            workspaceID: initialWorkspaceID,
            surfaceID: initialSurfaceID
        )
        pair.continuation.yield(.snapshot(try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: initialWorkspaceID,
                surfaceIDs: [initialSurfaceID]
            )]
        )))
        await settle()
        let initiallyAuthorized = await gate.isAuthorized(initialPlacement)
        #expect(initiallyAuthorized)

        pair.continuation.yield(.snapshot(try makeSnapshot(
            authority: authority,
            revision: 2,
            workspaces: [makeWorkspace(
                workspaceID: blockedWorkspaceID,
                surfaceIDs: [UUID()]
            )]
        )))
        await planner.waitUntilBlocked()
        pair.continuation.yield(.disconnected(authority))
        await settle()

        let authorizedAfterDisconnect = await gate.isAuthorized(initialPlacement)
        #expect(!authorizedAfterDisconnect)
        #expect(coordinator.debugInstalledRevision == nil)
        await planner.resume()
        await settle()
        #expect(projector.installedSnapshots.map(\.revision) == [1])
    }

    @Test @MainActor
    func staleDisconnectCannotClearNewAuthorityWhileItsPlanIsSuspended() async throws {
        let firstAuthority = makeAuthority()
        let secondAuthority = makeAuthority(sessionID: firstAuthority.sessionID)
        let firstWorkspaceID = UUID()
        let secondWorkspaceID = UUID()
        let secondSurfaceID = UUID()
        let planner = SuspendedTopologyPlanBuilder(blockedWorkspaceID: secondWorkspaceID)
        let projector = RecordingTopologyProjector()
        let gate = TerminalBackendTopologyAuthorizationGate()
        let pair = AsyncStream<TerminalBackendTopologyStreamEvent>.makeStream()
        let coordinator = TerminalBackendTopologyCoordinator(
            eventSource: { pair.stream },
            projector: projector,
            authorizationGate: gate,
            planBuilder: { topology in try await planner.build(topology) }
        )

        coordinator.startupRestoreDidFinish()
        coordinator.start()
        pair.continuation.yield(.snapshot(try makeSnapshot(
            authority: firstAuthority,
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: firstWorkspaceID,
                surfaceIDs: [UUID()]
            )]
        )))
        await settle()

        pair.continuation.yield(.snapshot(try makeSnapshot(
            authority: secondAuthority,
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: secondWorkspaceID,
                surfaceIDs: [secondSurfaceID]
            )]
        )))
        await planner.waitUntilBlocked()
        pair.continuation.yield(.disconnected(firstAuthority))
        await settle()
        await planner.resume()
        await settle()

        #expect(projector.installedSnapshots.map(\.authority) == [
            firstAuthority,
            secondAuthority,
        ])
        #expect(await gate.isAuthorized(TerminalBackendTopologyPlacement(
            workspaceID: secondWorkspaceID,
            surfaceID: secondSurfaceID
        )))
    }

    @Test @MainActor
    func processRegistryKeepsCanonicalWorkspacesInTheirRestoredWindows() throws {
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let firstWorkspaceID = UUID()
        let secondWorkspaceID = UUID()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let first = RecordingTopologyProjector(legacyPlacements: [
            TerminalBackendTopologyPlacement(
                workspaceID: firstWorkspaceID,
                surfaceID: firstSurfaceID
            ),
        ])
        let second = RecordingTopologyProjector(legacyPlacements: [
            TerminalBackendTopologyPlacement(
                workspaceID: secondWorkspaceID,
                surfaceID: secondSurfaceID
            ),
        ])
        let registry = TerminalBackendTopologyProjectionRegistry()
        registry.register(first, presentationID: firstWindowID, isPrimary: true)
        registry.register(second, presentationID: secondWindowID, isPrimary: false)
        let snapshot = try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [
                makeWorkspace(
                    workspaceID: firstWorkspaceID,
                    surfaceIDs: [firstSurfaceID]
                ),
                makeWorkspace(
                    workspaceID: secondWorkspaceID,
                    workspaceNumber: 2,
                    screenNumber: 2,
                    paneNumber: 2,
                    firstSurfaceNumber: 2,
                    surfaceIDs: [secondSurfaceID]
                ),
            ]
        )

        try registry.installCanonicalTopology(
            snapshot,
            plan: TerminalBackendTopologyProjectionPlan(topology: snapshot.topology)
        )

        #expect(first.installedPlans.last?.workspaces.map { $0.canonical.uuid.rawValue }
            == [firstWorkspaceID])
        #expect(second.installedPlans.last?.workspaces.map { $0.canonical.uuid.rawValue }
            == [secondWorkspaceID])
        #expect(registry.debugWorkspaceOwner(firstWorkspaceID) == firstWindowID)
        #expect(registry.debugWorkspaceOwner(secondWorkspaceID) == secondWindowID)
    }

    @Test @MainActor
    func newWorkspaceReservationProjectsIntoRequestingSecondaryWindow() throws {
        let primaryWindowID = UUID()
        let secondaryWindowID = UUID()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let primary = RecordingTopologyProjector()
        let secondary = RecordingTopologyProjector()
        let registry = TerminalBackendTopologyProjectionRegistry()
        registry.register(primary, presentationID: primaryWindowID, isPrimary: true)
        registry.register(secondary, presentationID: secondaryWindowID, isPrimary: false)

        let reservation = try registry.reserveWorkspaceOwner(
            workspaceID: workspaceID,
            for: secondary
        )
        #expect(reservation.presentationID == secondaryWindowID)
        let snapshot = try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: workspaceID,
                surfaceIDs: [surfaceID]
            )]
        )
        try registry.installCanonicalTopology(
            snapshot,
            plan: TerminalBackendTopologyProjectionPlan(topology: snapshot.topology)
        )

        #expect(primary.installedPlans.last?.workspaces.isEmpty == true)
        #expect(secondary.installedPlans.last?.workspaces.map {
            $0.canonical.uuid.rawValue
        } == [workspaceID])
        #expect(registry.debugWorkspaceOwner(workspaceID) == secondaryWindowID)
    }

    @Test @MainActor
    func emptyTopologyBootstrapClaimDeduplicatesWindowsAndTransfersAfterFailure() throws {
        let authority = makeAuthority()
        let primary = RecordingTopologyProjector()
        let secondary = RecordingTopologyProjector()
        let registry = TerminalBackendTopologyProjectionRegistry()
        registry.register(primary, presentationID: UUID(), isPrimary: true)
        registry.register(secondary, presentationID: UUID(), isPrimary: false)

        let firstClaim = try #require(registry.claimEmptyTopologyBootstrap(
            authority: authority,
            for: primary
        ))
        #expect(registry.claimEmptyTopologyBootstrap(
            authority: authority,
            for: secondary
        ) == nil)

        registry.releaseEmptyTopologyBootstrap(firstClaim)
        #expect(registry.claimEmptyTopologyBootstrap(
            authority: authority,
            for: secondary
        ) != nil)
    }

    @Test @MainActor
    func processRegistryRoutesMovedBrowserEndpointByStableSurfaceIdentity() throws {
        let primaryWindowID = UUID()
        let browserWindowID = UUID()
        let restoredWorkspaceID = UUID()
        let canonicalWorkspaceID = UUID()
        let browserSurfaceID = UUID()
        let primary = RecordingTopologyProjector()
        let browser = RecordingTopologyProjector(
            allPresentationPlacements: [TerminalBackendTopologyPlacement(
                workspaceID: restoredWorkspaceID,
                surfaceID: browserSurfaceID
            )]
        )
        let registry = TerminalBackendTopologyProjectionRegistry()
        registry.register(primary, presentationID: primaryWindowID, isPrimary: true)
        registry.register(browser, presentationID: browserWindowID, isPrimary: false)
        let pane = CanonicalPane(
            id: 1,
            uuid: CmuxTerminalBackend.PaneID(rawValue: UUID()),
            name: nil,
            tabs: [CanonicalSurface(
                id: 1,
                uuid: SurfaceID(rawValue: browserSurfaceID),
                kind: "browser",
                name: "browser"
            )]
        )
        let snapshot = try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [CanonicalWorkspace(
                id: 1,
                uuid: WorkspaceID(rawValue: canonicalWorkspaceID),
                name: "browser",
                screens: [CanonicalScreen(
                    id: 1,
                    uuid: ScreenID(rawValue: UUID()),
                    name: nil,
                    layout: .leaf(pane: pane.id, paneUUID: pane.uuid),
                    panes: [pane]
                )]
            )]
        )

        try registry.installCanonicalTopology(
            snapshot,
            plan: TerminalBackendTopologyProjectionPlan(topology: snapshot.topology)
        )

        #expect(primary.installedPlans.last?.workspaces.isEmpty == true)
        #expect(browser.installedPlans.last?.workspaces.map {
            $0.canonical.uuid.rawValue
        } == [canonicalWorkspaceID])
        #expect(registry.debugWorkspaceOwner(canonicalWorkspaceID) == browserWindowID)
    }

    @Test @MainActor
    func crossWindowSurfaceMoveFailsBeforeReplacingPresentationObjects() throws {
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let firstWorkspaceID = UUID()
        let secondWorkspaceID = UUID()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let first = RecordingTopologyProjector(legacyPlacements: [
            TerminalBackendTopologyPlacement(
                workspaceID: firstWorkspaceID,
                surfaceID: firstSurfaceID
            ),
        ])
        let second = RecordingTopologyProjector(legacyPlacements: [
            TerminalBackendTopologyPlacement(
                workspaceID: secondWorkspaceID,
                surfaceID: secondSurfaceID
            ),
        ])
        let registry = TerminalBackendTopologyProjectionRegistry()
        registry.register(first, presentationID: firstWindowID, isPrimary: true)
        registry.register(second, presentationID: secondWindowID, isPrimary: false)
        let authority = makeAuthority()
        let initial = try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [
                makeWorkspace(
                    workspaceID: firstWorkspaceID,
                    surfaceIDs: [firstSurfaceID]
                ),
                makeWorkspace(
                    workspaceID: secondWorkspaceID,
                    workspaceNumber: 2,
                    screenNumber: 2,
                    paneNumber: 2,
                    firstSurfaceNumber: 2,
                    surfaceIDs: [secondSurfaceID]
                ),
            ]
        )
        try registry.installCanonicalTopology(
            initial,
            plan: TerminalBackendTopologyProjectionPlan(topology: initial.topology)
        )
        let firstInstallCount = first.installedSnapshots.count
        let secondInstallCount = second.installedSnapshots.count

        let moved = try makeSnapshot(
            authority: authority,
            revision: 2,
            workspaces: [makeWorkspace(
                workspaceID: secondWorkspaceID,
                workspaceNumber: 2,
                screenNumber: 2,
                paneNumber: 2,
                firstSurfaceNumber: 1,
                surfaceIDs: [secondSurfaceID, firstSurfaceID]
            )]
        )

        #expect(throws: TerminalBackendTopologyProjectionError.self) {
            try registry.installCanonicalTopology(
                moved,
                plan: TerminalBackendTopologyProjectionPlan(topology: moved.topology)
            )
        }
        #expect(first.installedSnapshots.count == firstInstallCount)
        #expect(second.installedSnapshots.count == secondInstallCount)
        #expect(registry.debugWorkspaceOwner(firstWorkspaceID) == firstWindowID)
        #expect(registry.debugWorkspaceOwner(secondWorkspaceID) == secondWindowID)
    }

    @Test @MainActor
    func reservedCrossWindowTerminalMovePreservesExactPresentationObject() throws {
        let composition = makeProjectionComposition()
        let first = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: composition
        )
        let second = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: composition
        )
        defer {
            first.tabs.forEach { $0.teardownAllPanels() }
            second.tabs.forEach { $0.teardownAllPanels() }
        }
        let firstWorkspaceID = try #require(first.tabs.first?.id)
        let secondWorkspaceID = try #require(second.tabs.first?.id)
        let firstSurfaceID = try #require(first.tabs.first?.focusedPanelId)
        let secondSurfaceID = try #require(second.tabs.first?.focusedPanelId)
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let authority = makeAuthority()
        let registry = TerminalBackendTopologyProjectionRegistry()
        let firstPresentationID = UUID()
        let secondPresentationID = UUID()
        registry.register(first, presentationID: firstPresentationID, isPrimary: true)
        registry.register(second, presentationID: secondPresentationID, isPrimary: false)
        let initial = try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [
                makeWorkspace(
                    workspaceID: firstWorkspaceID,
                    paneID: firstPaneID,
                    surfaceIDs: [firstSurfaceID]
                ),
                makeWorkspace(
                    workspaceID: secondWorkspaceID,
                    workspaceNumber: 2,
                    screenNumber: 2,
                    paneNumber: 2,
                    paneID: secondPaneID,
                    firstSurfaceNumber: 2,
                    surfaceIDs: [secondSurfaceID]
                ),
            ]
        )
        try registry.installCanonicalTopology(
            initial,
            plan: TerminalBackendTopologyProjectionPlan(topology: initial.topology)
        )
        let sourceWorkspace = try #require(first.tabs.first)
        let original = try #require(
            sourceWorkspace.panels[firstSurfaceID] as? TerminalPanel
        )
        let originalSurface = original.surface
        let originalHostedView = original.hostedView

        _ = try registry.reserveCanonicalSurfaceMove(
            surfaceID: firstSurfaceID,
            from: firstWorkspaceID,
            in: first,
            to: secondWorkspaceID,
            in: second,
            destinationPaneID: secondPaneID,
            destinationIndex: 1
        )
        let moved = try makeSnapshot(
            authority: authority,
            revision: 2,
            workspaces: [makeWorkspace(
                workspaceID: secondWorkspaceID,
                workspaceNumber: 2,
                screenNumber: 2,
                paneNumber: 2,
                paneID: secondPaneID,
                firstSurfaceNumber: 2,
                surfaceIDs: [secondSurfaceID, firstSurfaceID]
            )]
        )
        try registry.installCanonicalTopology(
            moved,
            plan: TerminalBackendTopologyProjectionPlan(topology: moved.topology)
        )

        let destination = try #require(second.tabs.first(where: {
            $0.id == secondWorkspaceID
        }))
        let projected = try #require(
            destination.panels[firstSurfaceID] as? TerminalPanel
        )
        #expect(projected === original)
        #expect(projected.surface === originalSurface)
        #expect(projected.hostedView === originalHostedView)
        #expect(projected.workspaceId == secondWorkspaceID)
        #expect(first.tabs.allSatisfy { $0.panels[firstSurfaceID] == nil })
        #expect(destination.indexInPane(forPanelId: firstSurfaceID) == 1)
    }

    @Test @MainActor
    func detachAllTransferVaultSupportsCrossWindowSwap() throws {
        let composition = makeProjectionComposition()
        let first = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: composition
        )
        let second = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: composition
        )
        defer {
            first.tabs.forEach { $0.teardownAllPanels() }
            second.tabs.forEach { $0.teardownAllPanels() }
        }
        let firstWorkspaceID = try #require(first.tabs.first?.id)
        let secondWorkspaceID = try #require(second.tabs.first?.id)
        let firstSurfaceID = try #require(first.tabs.first?.focusedPanelId)
        let secondSurfaceID = try #require(second.tabs.first?.focusedPanelId)
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let authority = makeAuthority()
        let registry = TerminalBackendTopologyProjectionRegistry()
        registry.register(first, presentationID: UUID(), isPrimary: true)
        registry.register(second, presentationID: UUID(), isPrimary: false)
        let initial = try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [
                makeWorkspace(
                    workspaceID: firstWorkspaceID,
                    paneID: firstPaneID,
                    surfaceIDs: [firstSurfaceID]
                ),
                makeWorkspace(
                    workspaceID: secondWorkspaceID,
                    workspaceNumber: 2,
                    screenNumber: 2,
                    paneNumber: 2,
                    paneID: secondPaneID,
                    firstSurfaceNumber: 2,
                    surfaceIDs: [secondSurfaceID]
                ),
            ]
        )
        try registry.installCanonicalTopology(
            initial,
            plan: TerminalBackendTopologyProjectionPlan(topology: initial.topology)
        )
        let firstPanel = try #require(
            first.tabs.first?.panels[firstSurfaceID] as? TerminalPanel
        )
        let secondPanel = try #require(
            second.tabs.first?.panels[secondSurfaceID] as? TerminalPanel
        )

        _ = try registry.reserveCanonicalSurfaceMove(
            surfaceID: firstSurfaceID,
            from: firstWorkspaceID,
            in: first,
            to: secondWorkspaceID,
            in: second,
            destinationPaneID: secondPaneID,
            destinationIndex: 0
        )
        _ = try registry.reserveCanonicalSurfaceMove(
            surfaceID: secondSurfaceID,
            from: secondWorkspaceID,
            in: second,
            to: firstWorkspaceID,
            in: first,
            destinationPaneID: firstPaneID,
            destinationIndex: 0
        )
        let swapped = try makeSnapshot(
            authority: authority,
            revision: 2,
            workspaces: [
                makeWorkspace(
                    workspaceID: firstWorkspaceID,
                    paneID: firstPaneID,
                    firstSurfaceNumber: 2,
                    surfaceIDs: [secondSurfaceID]
                ),
                makeWorkspace(
                    workspaceID: secondWorkspaceID,
                    workspaceNumber: 2,
                    screenNumber: 2,
                    paneNumber: 2,
                    paneID: secondPaneID,
                    surfaceIDs: [firstSurfaceID]
                ),
            ]
        )
        try registry.installCanonicalTopology(
            swapped,
            plan: TerminalBackendTopologyProjectionPlan(topology: swapped.topology)
        )

        #expect(first.tabs.first?.panels[secondSurfaceID] === secondPanel)
        #expect(second.tabs.first?.panels[firstSurfaceID] === firstPanel)
        #expect(first.tabs.first?.panels[firstSurfaceID] == nil)
        #expect(second.tabs.first?.panels[secondSurfaceID] == nil)
    }

    @Test @MainActor
    func reservedCrossWindowBrowserMovePreservesPanelAndWebView() async throws {
        let movedBrowserID = SurfaceID(rawValue: UUID())
        let destinationBrowserID = SurfaceID(rawValue: UUID())
        let authority = makeAuthority()
        let sourceURL = try #require(URL(string: "https://example.com/source"))
        let destinationURL = try #require(URL(string: "https://example.com/destination"))
        let service = RecordingNativeBrowserService(
            authority: authority,
            retainedSources: [
                movedBrowserID: sourceURL,
                destinationBrowserID: destinationURL,
            ]
        )
        let native = makeNativeBrowserProjectionComposition(service: service)
        let first = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: native.composition
        )
        let second = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: native.composition
        )
        defer {
            first.tabs.forEach { $0.teardownAllPanels() }
            second.tabs.forEach { $0.teardownAllPanels() }
        }
        let firstWorkspaceID = try #require(first.tabs.first?.id)
        let secondWorkspaceID = try #require(second.tabs.first?.id)
        let firstTerminalID = try #require(first.tabs.first?.focusedPanelId)
        let secondTerminalID = try #require(second.tabs.first?.focusedPanelId)
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let registry = TerminalBackendTopologyProjectionRegistry()
        registry.register(first, presentationID: UUID(), isPrimary: true)
        registry.register(second, presentationID: UUID(), isPrimary: false)
        let initial = try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [
                makeMixedWorkspace(
                    workspaceID: firstWorkspaceID,
                    workspaceNumber: 1,
                    screenNumber: 1,
                    paneNumber: 1,
                    paneID: firstPaneID,
                    surfaces: [
                        makeSurface(id: 1, uuid: firstTerminalID, name: "terminal"),
                        makeFrontendNativeBrowserSurface(
                            id: 2,
                            uuid: movedBrowserID.rawValue
                        ),
                    ]
                ),
                makeMixedWorkspace(
                    workspaceID: secondWorkspaceID,
                    workspaceNumber: 2,
                    screenNumber: 2,
                    paneNumber: 2,
                    paneID: secondPaneID,
                    surfaces: [makeFrontendNativeBrowserSurface(
                        id: 3,
                        uuid: destinationBrowserID.rawValue
                    )]
                ),
            ]
        )
        let initialPlan = try TerminalBackendTopologyProjectionPlan(
            topology: initial.topology
        )
        try await native.runtime.claimBeforeProjection(
            authority: authority,
            surfaceIDs: initialPlan.frontendNativeBrowserSurfaceIDs,
            projector: registry
        )
        try registry.installCanonicalTopology(
            initial,
            plan: initialPlan
        )
        native.runtime.projectionDidInstall(
            surfaceIDs: initialPlan.frontendNativeBrowserSurfaceIDs,
            projector: registry
        )
        #expect(second.tabs.first?.panels[secondTerminalID] == nil)
        #expect(second.tabs.first?.panels.values.allSatisfy { $0 is BrowserPanel } == true)
        let original = try #require(
            first.tabs.first?.panels[movedBrowserID.rawValue] as? BrowserPanel
        )
        let originalWebView = original.webView

        _ = try registry.reserveCanonicalSurfaceMove(
            surfaceID: movedBrowserID.rawValue,
            from: firstWorkspaceID,
            in: first,
            to: secondWorkspaceID,
            in: second,
            destinationPaneID: secondPaneID,
            destinationIndex: 1
        )
        let moved = try makeSnapshot(
            authority: authority,
            revision: 2,
            workspaces: [
                makeMixedWorkspace(
                    workspaceID: firstWorkspaceID,
                    workspaceNumber: 1,
                    screenNumber: 1,
                    paneNumber: 1,
                    paneID: firstPaneID,
                    surfaces: [makeSurface(
                        id: 1,
                        uuid: firstTerminalID,
                        name: "terminal"
                    )]
                ),
                makeMixedWorkspace(
                    workspaceID: secondWorkspaceID,
                    workspaceNumber: 2,
                    screenNumber: 2,
                    paneNumber: 2,
                    paneID: secondPaneID,
                    surfaces: [
                        makeFrontendNativeBrowserSurface(
                            id: 3,
                            uuid: destinationBrowserID.rawValue
                        ),
                        makeFrontendNativeBrowserSurface(
                            id: 2,
                            uuid: movedBrowserID.rawValue
                        ),
                    ]
                ),
            ]
        )
        let movedPlan = try TerminalBackendTopologyProjectionPlan(
            topology: moved.topology
        )
        try await native.runtime.claimBeforeProjection(
            authority: authority,
            surfaceIDs: movedPlan.frontendNativeBrowserSurfaceIDs,
            projector: registry
        )
        try registry.installCanonicalTopology(
            moved,
            plan: movedPlan
        )
        native.runtime.projectionDidInstall(
            surfaceIDs: movedPlan.frontendNativeBrowserSurfaceIDs,
            projector: registry
        )

        let projected = try #require(
            second.tabs.first?.panels[movedBrowserID.rawValue] as? BrowserPanel
        )
        #expect(projected === original)
        #expect(projected.webView === originalWebView)
        #expect(projected.workspaceId == secondWorkspaceID)
        #expect(first.tabs.first?.panels[movedBrowserID.rawValue] == nil)
    }

    @Test @MainActor
    func crossWindowCommitFailureRestoresExactSourceGraphAndReservation() throws {
        let composition = makeProjectionComposition()
        let first = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: composition
        )
        let second = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: composition
        )
        defer {
            first.tabs.forEach { $0.teardownAllPanels() }
            second.tabs.forEach { $0.teardownAllPanels() }
        }
        let firstWorkspaceID = try #require(first.tabs.first?.id)
        let secondWorkspaceID = try #require(second.tabs.first?.id)
        let movedSurfaceID = try #require(first.tabs.first?.focusedPanelId)
        let retainedSurfaceID = UUID()
        let destinationSurfaceID = try #require(second.tabs.first?.focusedPanelId)
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let authority = makeAuthority()
        let registry = TerminalBackendTopologyProjectionRegistry()
        registry.register(first, presentationID: UUID(), isPrimary: true)
        registry.register(second, presentationID: UUID(), isPrimary: false)
        let initial = try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [
                makeWorkspace(
                    workspaceID: firstWorkspaceID,
                    paneID: firstPaneID,
                    surfaceIDs: [movedSurfaceID, retainedSurfaceID]
                ),
                makeWorkspace(
                    workspaceID: secondWorkspaceID,
                    workspaceNumber: 2,
                    screenNumber: 2,
                    paneNumber: 2,
                    paneID: secondPaneID,
                    firstSurfaceNumber: 3,
                    surfaceIDs: [destinationSurfaceID]
                ),
            ]
        )
        try registry.installCanonicalTopology(
            initial,
            plan: TerminalBackendTopologyProjectionPlan(topology: initial.topology)
        )
        let sourceWorkspace = try #require(first.tabs.first)
        let original = try #require(
            sourceWorkspace.panels[movedSurfaceID] as? TerminalPanel
        )
        let originalSurface = original.surface
        let originalHostedView = original.hostedView
        let originalPane = sourceWorkspace.paneId(forPanelId: movedSurfaceID)
        let originalIndex = sourceWorkspace.indexInPane(forPanelId: movedSurfaceID)
        let originalTree = sourceWorkspace.bonsplitController.treeSnapshot()
        let failing = RecordingTopologyProjector(failCommitRevisions: [2])
        registry.register(failing, presentationID: UUID(), isPrimary: false)
        _ = try registry.reserveCanonicalSurfaceMove(
            surfaceID: movedSurfaceID,
            from: firstWorkspaceID,
            in: first,
            to: secondWorkspaceID,
            in: second,
            destinationPaneID: secondPaneID,
            destinationIndex: 1
        )
        let moved = try makeSnapshot(
            authority: authority,
            revision: 2,
            workspaces: [
                makeWorkspace(
                    workspaceID: firstWorkspaceID,
                    paneID: firstPaneID,
                    firstSurfaceNumber: 2,
                    surfaceIDs: [retainedSurfaceID]
                ),
                makeWorkspace(
                    workspaceID: secondWorkspaceID,
                    workspaceNumber: 2,
                    screenNumber: 2,
                    paneNumber: 2,
                    paneID: secondPaneID,
                    firstSurfaceNumber: 3,
                    surfaceIDs: [destinationSurfaceID, movedSurfaceID]
                ),
            ]
        )

        #expect(throws: ProjectionTestError.self) {
            try registry.installCanonicalTopology(
                moved,
                plan: TerminalBackendTopologyProjectionPlan(topology: moved.topology)
            )
        }
        #expect(first.tabs.first === sourceWorkspace)
        #expect(sourceWorkspace.panels[movedSurfaceID] === original)
        #expect(original.surface === originalSurface)
        #expect(original.hostedView === originalHostedView)
        #expect(original.workspaceId == firstWorkspaceID)
        #expect(sourceWorkspace.paneId(forPanelId: movedSurfaceID) == originalPane)
        #expect(sourceWorkspace.indexInPane(forPanelId: movedSurfaceID) == originalIndex)
        #expect(sourceWorkspace.bonsplitController.treeSnapshot() == originalTree)
        #expect(second.tabs.first?.panels[movedSurfaceID] == nil)

        registry.unregister(failing)
        try registry.installCanonicalTopology(
            moved,
            plan: TerminalBackendTopologyProjectionPlan(topology: moved.topology)
        )
        #expect(second.tabs.first?.panels[movedSurfaceID] === original)
    }

    @Test @MainActor
    func newWorkspaceReservationsSelectExactWindowAndPresentationObject() throws {
        let composition = makeProjectionComposition()
        let first = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: composition
        )
        let second = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: composition
        )
        defer {
            first.tabs.forEach { $0.teardownAllPanels() }
            second.tabs.forEach { $0.teardownAllPanels() }
        }
        let firstWorkspaceID = try #require(first.tabs.first?.id)
        let secondWorkspaceID = try #require(second.tabs.first?.id)
        let movedSurfaceID = try #require(first.tabs.first?.focusedPanelId)
        let retainedSurfaceID = UUID()
        let destinationSurfaceID = try #require(second.tabs.first?.focusedPanelId)
        let newWorkspaceID = UUID()
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let newPaneID = UUID()
        let authority = makeAuthority()
        let registry = TerminalBackendTopologyProjectionRegistry()
        let firstPresentationID = UUID()
        let secondPresentationID = UUID()
        registry.register(first, presentationID: firstPresentationID, isPrimary: true)
        registry.register(second, presentationID: secondPresentationID, isPrimary: false)
        let initial = try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [
                makeWorkspace(
                    workspaceID: firstWorkspaceID,
                    paneID: firstPaneID,
                    surfaceIDs: [movedSurfaceID, retainedSurfaceID]
                ),
                makeWorkspace(
                    workspaceID: secondWorkspaceID,
                    workspaceNumber: 2,
                    screenNumber: 2,
                    paneNumber: 2,
                    paneID: secondPaneID,
                    firstSurfaceNumber: 3,
                    surfaceIDs: [destinationSurfaceID]
                ),
            ]
        )
        try registry.installCanonicalTopology(
            initial,
            plan: TerminalBackendTopologyProjectionPlan(topology: initial.topology)
        )
        let original = try #require(
            first.tabs.first?.panels[movedSurfaceID] as? TerminalPanel
        )
        _ = try registry.reserveWorkspaceOwner(workspaceID: newWorkspaceID, for: second)
        _ = try registry.reserveCanonicalSurfaceMove(
            surfaceID: movedSurfaceID,
            from: firstWorkspaceID,
            in: first,
            to: newWorkspaceID,
            in: second,
            destinationPaneID: newPaneID,
            destinationIndex: 0
        )
        let moved = try makeSnapshot(
            authority: authority,
            revision: 2,
            workspaces: [
                makeWorkspace(
                    workspaceID: firstWorkspaceID,
                    paneID: firstPaneID,
                    firstSurfaceNumber: 2,
                    surfaceIDs: [retainedSurfaceID]
                ),
                makeWorkspace(
                    workspaceID: secondWorkspaceID,
                    workspaceNumber: 2,
                    screenNumber: 2,
                    paneNumber: 2,
                    paneID: secondPaneID,
                    firstSurfaceNumber: 3,
                    surfaceIDs: [destinationSurfaceID]
                ),
                makeWorkspace(
                    workspaceID: newWorkspaceID,
                    workspaceNumber: 3,
                    screenNumber: 3,
                    paneNumber: 3,
                    paneID: newPaneID,
                    firstSurfaceNumber: 1,
                    surfaceIDs: [movedSurfaceID]
                ),
            ]
        )
        try registry.installCanonicalTopology(
            moved,
            plan: TerminalBackendTopologyProjectionPlan(topology: moved.topology)
        )

        #expect(first.tabs.allSatisfy { $0.id != newWorkspaceID })
        let newWorkspace = try #require(second.tabs.first(where: {
            $0.id == newWorkspaceID
        }))
        #expect(newWorkspace.panels[movedSurfaceID] === original)
        #expect(registry.debugWorkspaceOwner(newWorkspaceID)
            == secondPresentationID)
    }

    @Test @MainActor
    func canonicalInsertionIndexCountsTerminalAndBrowserButNotOverlay() throws {
        let browserFactory = RecordingBrowserEndpointFactory()
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: makeProjectionComposition(
                browserEndpointFactory: browserFactory
            )
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspaceID = try #require(manager.tabs.first?.id)
        let terminalID = try #require(manager.tabs.first?.focusedPanelId)
        let browserID = UUID()
        let paneID = UUID()
        let snapshot = try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [makeMixedWorkspace(
                workspaceID: workspaceID,
                workspaceNumber: 1,
                screenNumber: 1,
                paneNumber: 1,
                paneID: paneID,
                surfaces: [
                    makeSurface(id: 1, uuid: terminalID, name: "terminal"),
                    makeRequiredBrowserSurface(id: 2, uuid: browserID),
                ]
            )]
        )
        try manager.installCanonicalTopology(snapshot)
        let workspace = try #require(manager.tabs.first)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let overlay = try #require(workspace.newBrowserSurface(
            inPane: pane,
            focus: false,
            creationPolicy: .restoration
        ))
        let overlayTab = try #require(workspace.surfaceIdFromPanelId(overlay.id))
        workspace.isApplyingCanonicalTopologyProjection = true
        #expect(workspace.bonsplitController.reorderTab(overlayTab, toIndex: 1))
        workspace.isApplyingCanonicalTopologyProjection = false
        #expect(workspace.bonsplitController.tabs(inPane: pane).map(\.id.uuid) == [
            terminalID,
            overlay.id,
            browserID,
        ])

        #expect(workspace.backendCanonicalInsertionIndex(inPane: pane, presentedIndex: 0) == 0)
        #expect(workspace.backendCanonicalInsertionIndex(inPane: pane, presentedIndex: 1) == 1)
        #expect(workspace.backendCanonicalInsertionIndex(inPane: pane, presentedIndex: 2) == 1)
        #expect(workspace.backendCanonicalInsertionIndex(inPane: pane, presentedIndex: 3) == 2)
        #expect(manager.allPresentationPlacements() == [
            TerminalBackendTopologyPlacement(workspaceID: workspaceID, surfaceID: terminalID),
            TerminalBackendTopologyPlacement(workspaceID: workspaceID, surfaceID: browserID),
        ])
    }

    @Test @MainActor
    func wholeWorkspaceWindowMovePreservesEveryPresentationIdentity() throws {
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let first = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: .embedded()
        )
        let second = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: .embedded()
        )
        defer {
            first.tabs.forEach { $0.teardownAllPanels() }
            second.tabs.forEach { $0.teardownAllPanels() }
        }
        let originalWorkspace = try #require(first.tabs.first)
        let surfaceID = try #require(originalWorkspace.focusedPanelId)
        let originalPanel = try #require(
            originalWorkspace.panels[surfaceID] as? TerminalPanel
        )
        let originalSurface = originalPanel.surface
        let originalHostedView = originalPanel.hostedView
        let registry = TerminalBackendTopologyProjectionRegistry()
        registry.register(first, presentationID: firstWindowID, isPrimary: true)
        registry.register(second, presentationID: secondWindowID, isPrimary: false)
        let authority = makeAuthority()
        let initial = try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: originalWorkspace.id,
                surfaceIDs: [surfaceID]
            )]
        )
        try registry.installCanonicalTopology(
            initial,
            plan: TerminalBackendTopologyProjectionPlan(topology: initial.topology)
        )
        let transfer = try registry.prepareWorkspaceOwnershipTransfer(
            workspaceID: originalWorkspace.id,
            from: first,
            to: second
        )

        try transfer.commit()
        let detached = try #require(first.detachWorkspace(
            tabId: originalWorkspace.id,
            provisionReplacementIfEmpty: false
        ))
        second.attachWorkspace(detached, select: true)
        #expect(first.tabs.isEmpty)

        let next = try makeSnapshot(
            authority: authority,
            revision: 2,
            workspaces: [makeWorkspace(
                workspaceID: originalWorkspace.id,
                surfaceIDs: [surfaceID]
            )]
        )
        try registry.installCanonicalTopology(
            next,
            plan: TerminalBackendTopologyProjectionPlan(topology: next.topology)
        )

        let movedWorkspace = try #require(second.tabs.first(where: {
            $0.id == originalWorkspace.id
        }))
        let movedPanel = try #require(movedWorkspace.panels[surfaceID] as? TerminalPanel)
        #expect(movedWorkspace === originalWorkspace)
        #expect(movedPanel === originalPanel)
        #expect(movedPanel.surface === originalSurface)
        #expect(movedPanel.hostedView === originalHostedView)
        #expect(registry.debugWorkspaceOwner(originalWorkspace.id) == secondWindowID)
    }

    @Test @MainActor
    func closedWindowOwnershipStaysDormantUntilSameWindowReturns() throws {
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let first = RecordingTopologyProjector()
        let second = RecordingTopologyProjector(legacyPlacements: [
            TerminalBackendTopologyPlacement(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ),
        ])
        let registry = TerminalBackendTopologyProjectionRegistry()
        registry.register(first, presentationID: firstWindowID, isPrimary: true)
        registry.register(second, presentationID: secondWindowID, isPrimary: false)
        let snapshot = try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: workspaceID,
                surfaceIDs: [surfaceID]
            )]
        )
        let plan = try TerminalBackendTopologyProjectionPlan(topology: snapshot.topology)
        try registry.installCanonicalTopology(snapshot, plan: plan)

        registry.unregister(second)
        try registry.installCanonicalTopology(snapshot, plan: plan)
        #expect(first.installedPlans.last?.workspaces.isEmpty == true)

        let restoredSecond = RecordingTopologyProjector()
        registry.register(
            restoredSecond,
            presentationID: secondWindowID,
            isPrimary: false
        )
        try registry.installCanonicalTopology(snapshot, plan: plan)

        #expect(restoredSecond.installedPlans.last?.workspaces.map {
            $0.canonical.uuid.rawValue
        } == [workspaceID])
    }

    @Test @MainActor
    func processRegistryPreparationFailureLeavesEveryWindowAndOwnerUnchanged() throws {
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let firstWorkspaceID = UUID()
        let secondWorkspaceID = UUID()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let first = RecordingTopologyProjector(legacyPlacements: [
            TerminalBackendTopologyPlacement(
                workspaceID: firstWorkspaceID,
                surfaceID: firstSurfaceID
            ),
        ])
        let second = RecordingTopologyProjector(
            legacyPlacements: [TerminalBackendTopologyPlacement(
                workspaceID: secondWorkspaceID,
                surfaceID: secondSurfaceID
            )],
            failPreparation: true
        )
        let registry = TerminalBackendTopologyProjectionRegistry()
        registry.register(first, presentationID: firstWindowID, isPrimary: true)
        registry.register(second, presentationID: secondWindowID, isPrimary: false)
        let snapshot = try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [
                makeWorkspace(
                    workspaceID: firstWorkspaceID,
                    surfaceIDs: [firstSurfaceID]
                ),
                makeWorkspace(
                    workspaceID: secondWorkspaceID,
                    workspaceNumber: 2,
                    screenNumber: 2,
                    paneNumber: 2,
                    firstSurfaceNumber: 2,
                    surfaceIDs: [secondSurfaceID]
                ),
            ]
        )

        #expect(throws: ProjectionTestError.self) {
            try registry.installCanonicalTopology(
                snapshot,
                plan: TerminalBackendTopologyProjectionPlan(topology: snapshot.topology)
            )
        }

        #expect(first.installedSnapshots.isEmpty)
        #expect(second.installedSnapshots.isEmpty)
        #expect(registry.debugWorkspaceOwner(firstWorkspaceID) == nil)
        #expect(registry.debugWorkspaceOwner(secondWorkspaceID) == nil)
    }

    @Test @MainActor
    func processRegistryLaterCommitFailureRollsBackEarlierWindowAndOwners() throws {
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let firstWorkspaceID = UUID()
        let secondWorkspaceID = UUID()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let first = RecordingTopologyProjector(legacyPlacements: [
            TerminalBackendTopologyPlacement(
                workspaceID: firstWorkspaceID,
                surfaceID: firstSurfaceID
            ),
        ])
        let second = RecordingTopologyProjector(
            legacyPlacements: [TerminalBackendTopologyPlacement(
                workspaceID: secondWorkspaceID,
                surfaceID: secondSurfaceID
            )],
            failCommitRevisions: [1]
        )
        let registry = TerminalBackendTopologyProjectionRegistry()
        registry.register(first, presentationID: firstWindowID, isPrimary: true)
        registry.register(second, presentationID: secondWindowID, isPrimary: false)
        let snapshot = try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [
                makeWorkspace(
                    workspaceID: firstWorkspaceID,
                    surfaceIDs: [firstSurfaceID]
                ),
                makeWorkspace(
                    workspaceID: secondWorkspaceID,
                    workspaceNumber: 2,
                    screenNumber: 2,
                    paneNumber: 2,
                    firstSurfaceNumber: 2,
                    surfaceIDs: [secondSurfaceID]
                ),
            ]
        )

        #expect(throws: ProjectionTestError.self) {
            try registry.installCanonicalTopology(
                snapshot,
                plan: TerminalBackendTopologyProjectionPlan(topology: snapshot.topology)
            )
        }

        #expect(first.installedSnapshots.isEmpty)
        #expect(second.installedSnapshots.isEmpty)
        #expect(registry.debugWorkspaceOwner(firstWorkspaceID) == nil)
        #expect(registry.debugWorkspaceOwner(secondWorkspaceID) == nil)
    }

    @Test @MainActor
    func processRegistryFailureRestoresRealTabManagerObjectGraphExactly() throws {
        let managerPresentationID = UUID()
        let failingPresentationID = UUID()
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: makeProjectionComposition()
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let originalWorkspace = try #require(manager.tabs.first)
        let originalSurfaceID = try #require(originalWorkspace.focusedPanelId)
        let originalPanel = try #require(
            originalWorkspace.panels[originalSurfaceID] as? TerminalPanel
        )
        let originalSurface = originalPanel.surface
        let originalHostedView = originalPanel.hostedView
        let originalTree = originalWorkspace.bonsplitController.treeSnapshot()
        let originalTabID = try #require(
            originalWorkspace.surfaceIdFromPanelId(originalSurfaceID)
        )
        let originalTitle = originalWorkspace.title
        let originalProcessTitle = originalWorkspace.processTitle
        let originalCustomTitle = originalWorkspace.customTitle
        let originalPanelTitles = originalWorkspace.panelTitles
        let originalSelection = manager.selectedTabId
        let createdCanonicalSurfaceID = UUID()
        let failingWorkspaceID = UUID()
        let failingSurfaceID = UUID()
        let failing = RecordingTopologyProjector(
            legacyPlacements: [TerminalBackendTopologyPlacement(
                workspaceID: failingWorkspaceID,
                surfaceID: failingSurfaceID
            )],
            failCommitRevisions: [1]
        )
        let registry = TerminalBackendTopologyProjectionRegistry()
        registry.register(
            manager,
            presentationID: managerPresentationID,
            isPrimary: true
        )
        registry.register(
            failing,
            presentationID: failingPresentationID,
            isPrimary: false
        )
        let snapshot = try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [
                makeWorkspace(
                    workspaceID: originalWorkspace.id,
                    workspaceName: "must roll back",
                    surfaceIDs: [originalSurfaceID, createdCanonicalSurfaceID]
                ),
                makeWorkspace(
                    workspaceID: failingWorkspaceID,
                    workspaceNumber: 2,
                    screenNumber: 2,
                    paneNumber: 2,
                    firstSurfaceNumber: 3,
                    surfaceIDs: [failingSurfaceID]
                ),
            ]
        )

        #expect(throws: ProjectionTestError.self) {
            try registry.installCanonicalTopology(
                snapshot,
                plan: TerminalBackendTopologyProjectionPlan(topology: snapshot.topology)
            )
        }

        let restoredWorkspace = try #require(manager.tabs.first)
        let restoredPanel = try #require(
            restoredWorkspace.panels[originalSurfaceID] as? TerminalPanel
        )
        #expect(manager.tabs.count == 1)
        #expect(restoredWorkspace === originalWorkspace)
        #expect(restoredWorkspace.panels.count == 1)
        #expect(restoredWorkspace.panels[createdCanonicalSurfaceID] == nil)
        #expect(restoredPanel === originalPanel)
        #expect(restoredPanel.surface === originalSurface)
        #expect(restoredPanel.hostedView === originalHostedView)
        #expect(restoredWorkspace.surfaceIdFromPanelId(originalSurfaceID) == originalTabID)
        #expect(restoredWorkspace.bonsplitController.treeSnapshot() == originalTree)
        #expect(restoredWorkspace.title == originalTitle)
        #expect(restoredWorkspace.processTitle == originalProcessTitle)
        #expect(restoredWorkspace.customTitle == originalCustomTitle)
        #expect(restoredWorkspace.panelTitles == originalPanelTitles)
        #expect(manager.selectedTabId == originalSelection)
        #expect(registry.debugWorkspaceOwner(originalWorkspace.id) == nil)
        #expect(registry.debugWorkspaceOwner(failingWorkspaceID) == nil)
    }

    @Test
    func unsupportedStructuralMutationsAreExhaustive() {
        #expect(TerminalBackendTopologyMutationCoordinator.supportedMutations == [
            .closeTerminal,
            .reparentTerminal,
        ])
        #expect(
            Set(TerminalBackendTopologyMutation.allCases)
                .subtracting(TerminalBackendTopologyMutationCoordinator.supportedMutations)
            == [
                .createWorkspace,
                .closeWorkspace,
                .renameWorkspace,
                .splitPane,
                .closePane,
                .attachSurface,
                .renameSurface,
                .moveTab,
                .reorderTab,
                .reorderWorkspace,
                .changeSplitRatio,
            ]
        )
    }

    @Test
    func structuralProjectionPlanScalesToOneThousandDormantWorkspaces() throws {
        let workspaces = (0..<1_000).map { index in
            makeWorkspace(
                workspaceID: UUID(),
                workspaceName: "workspace \(index)",
                workspaceNumber: UInt64(index + 1),
                screenNumber: UInt64(index + 1),
                paneNumber: UInt64(index + 1),
                firstSurfaceNumber: UInt64(index + 1),
                surfaceIDs: [UUID()]
            )
        }
        let topology = try CanonicalTopology(workspaces: workspaces)

        let plan = try TerminalBackendTopologyProjectionPlan(topology: topology)

        #expect(plan.workspaces.count == 1_000)
        #expect(plan.placements.count == 1_000)
        #expect(plan.surfaceWorkspaceIDs.count == 1_000)
        #expect(Set(plan.surfaceWorkspaceIDs.values).count == 1_000)
    }

    @Test
    func supersededStructuralProjectionStopsBeforeScanningTheTopology() async throws {
        let workspaces = (0..<1_000).map { index in
            makeWorkspace(
                workspaceID: UUID(),
                workspaceNumber: UInt64(index + 1),
                screenNumber: UInt64(index + 1),
                paneNumber: UInt64(index + 1),
                firstSurfaceNumber: UInt64(index + 1),
                surfaceIDs: [UUID()]
            )
        }
        let topology = try CanonicalTopology(workspaces: workspaces)
        let gate = ProjectionPlanCancellationGate()
        let task = Task.detached {
            await gate.suspend()
            return try TerminalBackendTopologyProjectionPlan(topology: topology)
        }
        await gate.waitUntilSuspended()
        task.cancel()
        await gate.resume()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test @MainActor
    func everyUnsupportedMutationReportsAndReturnsFalse() {
        var failures: [String] = []
        let coordinator = TerminalBackendTopologyMutationCoordinator {
            failures.append($0)
        }
        let unsupported = Set(TerminalBackendTopologyMutation.allCases)
            .subtracting(TerminalBackendTopologyMutationCoordinator.supportedMutations)

        for mutation in unsupported {
            #expect(coordinator.reject(mutation) == false)
        }

        #expect(failures.count == unsupported.count)
        for mutation in unsupported {
            #expect(failures.contains(where: { $0.contains(mutation.rawValue) }))
        }
    }

    @Test @MainActor
    func projectionCallbacksWaitForOwningWindowAcrossBothFinalizeOrders() async throws {
        let authority = makeAuthority()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let primaryWindowID = UUID()
        let secondaryWindowID = UUID()
        let placement = try makeSurfacePlacement(
            authority: authority,
            revision: 2,
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        let snapshot = try makeSnapshot(
            authority: authority,
            revision: 2,
            workspaces: [makeWorkspace(
                workspaceID: workspaceID,
                surfaceIDs: [surfaceID]
            )]
        )

        var receiptFirstCallbacks = 0
        let receiptFirst = TerminalBackendTopologyMutationCoordinator(
            mutator: RejectingTopologyMutator(createWorkspacePlacement: placement)
        )
        let receiptFirstSubmission = receiptFirst.requestCreateWorkspace(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            projectionOwnerID: secondaryWindowID,
            onProjected: { _ in receiptFirstCallbacks += 1 }
        )
        await settle()
        #expect(receiptFirst.submissionStatus(
            requestID: receiptFirstSubmission.requestID
        ) == .committed(placement.receipt))

        receiptFirst.canonicalProjectionDidInstall(
            snapshot,
            presentationID: primaryWindowID
        )
        #expect(receiptFirstCallbacks == 0)
        #expect(receiptFirst.submissionStatus(
            requestID: receiptFirstSubmission.requestID
        ) == .committed(placement.receipt))

        receiptFirst.canonicalProjectionDidInstall(
            snapshot,
            presentationID: secondaryWindowID
        )
        #expect(receiptFirstCallbacks == 1)
        #expect(receiptFirst.submissionStatus(
            requestID: receiptFirstSubmission.requestID
        ) == .projected(placement.receipt))

        var projectionFirstCallbacks = 0
        let projectionFirst = TerminalBackendTopologyMutationCoordinator(
            mutator: RejectingTopologyMutator(createWorkspacePlacement: placement)
        )
        let projectionFirstSubmission = projectionFirst.requestCreateWorkspace(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            projectionOwnerID: secondaryWindowID,
            onProjected: { _ in projectionFirstCallbacks += 1 }
        )
        projectionFirst.canonicalProjectionDidInstall(
            snapshot,
            presentationID: secondaryWindowID
        )
        await settle()

        #expect(projectionFirstCallbacks == 1)
        #expect(projectionFirst.submissionStatus(
            requestID: projectionFirstSubmission.requestID
        ) == .projected(placement.receipt))
    }

    @Test @MainActor
    func projectionUsesCanonicalWorkspaceAndSurfaceIDsAcrossWorkspaceMove() throws {
        let composition = makeProjectionComposition()
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: composition
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let firstWorkspaceID = UUID()
        let secondWorkspaceID = UUID()
        let surfaceID = UUID()
        let authority = makeAuthority()

        try manager.installCanonicalTopology(try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [makeWorkspace(workspaceID: firstWorkspaceID, surfaceIDs: [surfaceID])]
        ))
        #expect(manager.tabs.map(\.id) == [firstWorkspaceID])
        let originalPanel = try #require(manager.tabs[0].panels[surfaceID] as? TerminalPanel)
        let originalSurface = originalPanel.surface
        let originalHostedView = originalPanel.hostedView

        try manager.installCanonicalTopology(try makeSnapshot(
            authority: authority,
            revision: 2,
            workspaces: [makeWorkspace(workspaceID: firstWorkspaceID, surfaceIDs: [surfaceID])]
        ))

        #expect(manager.tabs[0].panels[surfaceID] === originalPanel)
        #expect((manager.tabs[0].panels[surfaceID] as? TerminalPanel)?.surface === originalSurface)
        #expect((manager.tabs[0].panels[surfaceID] as? TerminalPanel)?.hostedView === originalHostedView)

        try manager.installCanonicalTopology(try makeSnapshot(
            authority: authority,
            revision: 3,
            workspaces: [makeWorkspace(workspaceID: secondWorkspaceID, surfaceIDs: [surfaceID])]
        ))

        #expect(manager.tabs.map(\.id) == [secondWorkspaceID])
        #expect(manager.tabs[0].panels[surfaceID] === originalPanel)
        #expect((manager.tabs[0].panels[surfaceID] as? TerminalPanel)?.surface === originalSurface)
        #expect((manager.tabs[0].panels[surfaceID] as? TerminalPanel)?.hostedView === originalHostedView)
        #expect(manager.tabs.flatMap { $0.panels.keys }.filter { $0 == surfaceID }.count == 1)
    }

    @Test @MainActor
    func renameOnlySnapshotPreservesWorkspaceAndTerminalPresentationIdentity() throws {
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: makeProjectionComposition()
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspaceID = UUID()
        let surfaceID = UUID()
        let authority = makeAuthority()

        try manager.installCanonicalTopology(try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: workspaceID,
                workspaceName: "before",
                surfaceIDs: [surfaceID]
            )]
        ))
        let originalWorkspace = try #require(manager.tabs.first)
        let originalPanel = try #require(originalWorkspace.panels[surfaceID] as? TerminalPanel)
        let originalSurface = originalPanel.surface
        let originalHostedView = originalPanel.hostedView

        try manager.installCanonicalTopology(try makeSnapshot(
            authority: authority,
            revision: 2,
            workspaces: [makeWorkspace(
                workspaceID: workspaceID,
                workspaceName: "after",
                surfaceIDs: [surfaceID]
            )]
        ))

        let reconciledWorkspace = try #require(manager.tabs.first)
        let reconciledPanel = try #require(reconciledWorkspace.panels[surfaceID] as? TerminalPanel)
        #expect(reconciledWorkspace === originalWorkspace)
        #expect(reconciledPanel === originalPanel)
        #expect(reconciledPanel.surface === originalSurface)
        #expect(reconciledPanel.hostedView === originalHostedView)
        #expect(reconciledWorkspace.title == "after")
    }

    @Test @MainActor
    func projectionPreservesClientOwnedBrowserObjectAsOverlay() throws {
        let composition = makeProjectionComposition()
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: composition
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let oldWorkspace = try #require(manager.tabs.first)
        let paneID = try #require(oldWorkspace.bonsplitController.allPaneIds.first)
        let browser = try #require(oldWorkspace.newBrowserSurface(
            inPane: paneID,
            focus: false,
            creationPolicy: .restoration
        ))
        let canonicalSurfaceID = UUID()

        try manager.installCanonicalTopology(try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: oldWorkspace.id,
                surfaceIDs: [canonicalSurfaceID]
            )]
        ))

        let projectedWorkspace = try #require(manager.tabs.first)
        let preserved = try #require(projectedWorkspace.panels[browser.id] as? BrowserPanel)
        #expect(preserved === browser)
        #expect(projectedWorkspace.panels[canonicalSurfaceID] is TerminalPanel)
    }

    @Test @MainActor
    func exactCloudLoadingPermitAdoptsCanonicalTerminalInPlace() throws {
        let composition = makeProjectionComposition()
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: composition
        )
        let previousWorkspace = try #require(manager.tabs.first)
        previousWorkspace.teardownAllPanels()
        let workspaceID = UUID()
        let workspace = Workspace(
            id: workspaceID,
            initialSurface: .cloudVMLoading,
            terminalClientComposition: composition
        )
        workspace.owningTabManager = manager
        manager.tabs = [workspace]
        manager.selectedTabId = workspaceID
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let loading = try #require(
            workspace.panels.values.first { $0 is CloudVMLoadingPanel }
                as? CloudVMLoadingPanel
        )
        let surfaceID = loading.id
        let stableSurfaceID = loading.stableSurfaceId
        let adoptionRegistry = try #require(
            composition.terminalBackendTopologyAdoptionRegistry
        )
        adoptionRegistry.beginCloudTerminalAdoption(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )

        try manager.installCanonicalTopology(try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: workspaceID,
                surfaceIDs: [surfaceID]
            )]
        ))

        let terminal = try #require(workspace.panels[surfaceID] as? TerminalPanel)
        #expect(terminal.id == surfaceID)
        #expect(terminal.stableSurfaceId == stableSurfaceID)
        #expect(!adoptionRegistry.permitsCloudTerminalAdoption(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        ))
    }

    @Test @MainActor
    func cloudTerminalAdoptionRollbackRestoresLoadingPanelAndPermit() throws {
        let composition = makeProjectionComposition()
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: composition
        )
        let previousWorkspace = try #require(manager.tabs.first)
        previousWorkspace.teardownAllPanels()
        let workspaceID = UUID()
        let workspace = Workspace(
            id: workspaceID,
            initialSurface: .cloudVMLoading,
            terminalClientComposition: composition
        )
        workspace.owningTabManager = manager
        manager.tabs = [workspace]
        manager.selectedTabId = workspaceID
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let loading = try #require(
            workspace.panels.values.first { $0 is CloudVMLoadingPanel }
                as? CloudVMLoadingPanel
        )
        let surfaceID = loading.id
        let adoptionRegistry = try #require(
            composition.terminalBackendTopologyAdoptionRegistry
        )
        adoptionRegistry.beginCloudTerminalAdoption(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        let snapshot = try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [makeWorkspace(
                workspaceID: workspaceID,
                surfaceIDs: [surfaceID]
            )]
        )
        let prepared = try manager.prepareCanonicalTopology(
            snapshot,
            plan: TerminalBackendTopologyProjectionPlan(topology: snapshot.topology)
        )

        try prepared.commit()
        #expect(workspace.panels[surfaceID] is TerminalPanel)
        try prepared.rollback()

        #expect(workspace.panels[surfaceID] === loading)
        #expect(adoptionRegistry.permitsCloudTerminalAdoption(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        ))
    }

    @Test @MainActor
    func projectionPreservesStandaloneBrowserSplitStructure() throws {
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: makeProjectionComposition()
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.tabs.first)
        let terminalID = try #require(workspace.focusedPanelId)
        let terminalPane = try #require(workspace.paneId(forPanelId: terminalID))
        let browser = try #require(workspace.newBrowserSplit(
            from: terminalID,
            orientation: .horizontal,
            focus: false,
            creationPolicy: .restoration,
            initialDividerPosition: 0.62
        ))
        let browserPane = try #require(workspace.paneId(forPanelId: browser.id))

        try manager.installCanonicalTopology(try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [CanonicalWorkspace(
                id: 1,
                uuid: WorkspaceID(rawValue: workspace.id),
                name: "canonical",
                screens: [CanonicalScreen(
                    id: 1,
                    uuid: ScreenID(rawValue: UUID()),
                    name: nil,
                    layout: .leaf(
                        pane: 1,
                        paneUUID: CmuxTerminalBackend.PaneID(rawValue: terminalPane.id)
                    ),
                    panes: [CanonicalPane(
                        id: 1,
                        uuid: CmuxTerminalBackend.PaneID(rawValue: terminalPane.id),
                        name: nil,
                        tabs: [makeSurface(id: 1, uuid: terminalID, name: "terminal")]
                    )]
                )]
            )]
        ))

        guard case .split(let split) = workspace.bonsplitController.treeSnapshot() else {
            Issue.record("Expected browser overlay split to survive")
            return
        }
        #expect(split.orientation == "horizontal")
        #expect(abs(split.dividerPosition - 0.62) < 0.0001)
        #expect(Set(workspace.bonsplitController.allPaneIds.map(\.id)) == [
            terminalPane.id,
            browserPane.id,
        ])
        #expect(workspace.panels[browser.id] === browser)
    }

    @Test @MainActor
    func canonicalNativeBrowserRestoresOnlyThroughPrivateClaim() async throws {
        let authority = makeAuthority()
        let workspaceID = UUID()
        let surfaceID = SurfaceID(rawValue: UUID())
        let sourceURL = try #require(URL(string: "https://example.com/private-source"))
        let service = RecordingNativeBrowserService(
            authority: authority,
            retainedSources: [surfaceID: sourceURL]
        )
        let first = makeNativeBrowserProjectionComposition(service: service)
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: first.composition
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let canonical = makeBrowserWorkspace(
            workspaceID: workspaceID,
            surface: makeFrontendNativeBrowserSurface(id: 1, uuid: surfaceID.rawValue)
        )
        let snapshot = try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [canonical]
        )
        let plan = try TerminalBackendTopologyProjectionPlan(topology: snapshot.topology)

        try await first.runtime.claimBeforeProjection(
            authority: authority,
            surfaceIDs: plan.frontendNativeBrowserSurfaceIDs,
            projector: manager
        )
        try manager.installCanonicalTopology(snapshot, plan: plan)
        first.runtime.projectionDidInstall(
            surfaceIDs: plan.frontendNativeBrowserSurfaceIDs,
            projector: manager
        )

        let browser = try #require(manager.tabs.first?.panels[surfaceID.rawValue] as? BrowserPanel)
        #expect(browser.endpointProvenance == .frontendNativeCanonical(surfaceID))
        #expect(browser.currentURLForTabDuplication == sourceURL)
        #expect(!browser.shouldPersistSessionSnapshot())
        let swiftSnapshot = manager.sessionSnapshot(includeScrollback: false)
        #expect(swiftSnapshot.workspaces.flatMap(\.panels).allSatisfy {
            $0.type != .browser
        })

        let second = makeNativeBrowserProjectionComposition(service: service)
        let restored = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: second.composition
        )
        defer { restored.tabs.forEach { $0.teardownAllPanels() } }
        restored.restoreSessionSnapshot(swiftSnapshot)
        #expect(restored.tabs.flatMap { $0.panels.values }.allSatisfy {
            !($0 is BrowserPanel)
        })

        try await second.runtime.claimBeforeProjection(
            authority: authority,
            surfaceIDs: plan.frontendNativeBrowserSurfaceIDs,
            projector: restored
        )
        try restored.installCanonicalTopology(snapshot, plan: plan)
        second.runtime.projectionDidInstall(
            surfaceIDs: plan.frontendNativeBrowserSurfaceIDs,
            projector: restored
        )
        let restoredBrowser = try #require(
            restored.tabs.first?.panels[surfaceID.rawValue] as? BrowserPanel
        )
        #expect(restoredBrowser.currentURLForTabDuplication == sourceURL)
    }

    @Test @MainActor
    func nativeBrowserPrivateRequestRegistryFailsClosedAtCapacity() throws {
        let registry = TerminalBackendNativeBrowserPresentationRegistry(
            maximumPendingRequestCount: 2
        )
        let firstSurfaceID = SurfaceID(rawValue: UUID())
        let secondSurfaceID = SurfaceID(rawValue: UUID())
        let rejectedSurfaceID = SurfaceID(rawValue: UUID())
        var credentialRequest = URLRequest(
            url: try #require(URL(string: "https://example.com/private"))
        )
        credentialRequest.setValue(
            "Bearer private-token",
            forHTTPHeaderField: "Authorization"
        )
        let privateRequest = TerminalBackendNativeBrowserPresentationRequest(
            url: credentialRequest.url,
            initialRequest: credentialRequest,
            profileID: nil,
            omnibarVisible: true,
            transparentBackground: false
        )
        let ordinaryRequest = TerminalBackendNativeBrowserPresentationRequest(
            url: try #require(URL(string: "https://example.com/second")),
            profileID: nil,
            omnibarVisible: true,
            transparentBackground: false
        )

        #expect(registry.register(privateRequest, for: firstSurfaceID))
        #expect(registry.register(ordinaryRequest, for: secondSurfaceID))
        #expect(!registry.register(ordinaryRequest, for: rejectedSurfaceID))
        #expect(registry.pendingRequestCount == 2)
        #expect(registry.request(for: firstSurfaceID)?.initialRequest?
            .value(forHTTPHeaderField: "Authorization") == "Bearer private-token")

        registry.remove(firstSurfaceID)
        #expect(registry.register(ordinaryRequest, for: rejectedSurfaceID))
        #expect(registry.pendingRequestCount == 2)
    }

    @Test @MainActor
    func nativeBrowserProjectionRollbackRetainsCredentialRequestUntilRetryCommits() async throws {
        let authority = makeAuthority()
        let workspaceID = UUID()
        let surfaceID = SurfaceID(rawValue: UUID())
        let sourceURL = try #require(URL(string: "https://example.com/credentialed"))
        var credentialRequest = URLRequest(url: sourceURL)
        credentialRequest.setValue(
            "Bearer retry-token",
            forHTTPHeaderField: "Authorization"
        )
        let service = RecordingNativeBrowserService(authority: authority)
        let native = makeNativeBrowserProjectionComposition(service: service)
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: native.composition
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        #expect(native.registry.register(
            TerminalBackendNativeBrowserPresentationRequest(
                url: sourceURL,
                initialRequest: credentialRequest,
                profileID: nil,
                omnibarVisible: true,
                transparentBackground: false
            ),
            for: surfaceID
        ))
        let snapshot = try makeSnapshot(
            authority: authority,
            revision: 1,
            workspaces: [makeBrowserWorkspace(
                workspaceID: workspaceID,
                surface: makeFrontendNativeBrowserSurface(
                    id: 1,
                    uuid: surfaceID.rawValue
                )
            )]
        )
        let plan = try TerminalBackendTopologyProjectionPlan(
            topology: snapshot.topology
        )
        try await native.runtime.claimBeforeProjection(
            authority: authority,
            surfaceIDs: plan.frontendNativeBrowserSurfaceIDs,
            projector: manager
        )

        let firstAttempt = try manager.prepareCanonicalTopology(snapshot, plan: plan)
        try firstAttempt.commit()
        try firstAttempt.rollback()
        #expect(native.registry.request(for: surfaceID)?.initialRequest?
            .value(forHTTPHeaderField: "Authorization") == "Bearer retry-token")

        let retry = try manager.prepareCanonicalTopology(snapshot, plan: plan)
        try retry.commit()
        retry.finalize()
        native.runtime.projectionDidInstall(
            surfaceIDs: plan.frontendNativeBrowserSurfaceIDs,
            projector: manager
        )
        #expect(native.registry.request(for: surfaceID) == nil)
        #expect(await service.claimCallSnapshot().count == 1)
    }

    @Test @MainActor
    func nativeBrowserClaimsUseBoundedConcurrency() async throws {
        let authority = makeAuthority()
        let surfaceIDs = (0..<40).map { _ in SurfaceID(rawValue: UUID()) }
        let service = RecordingNativeBrowserService(authority: authority)
        await service.setClaimDelay(nanoseconds: 10_000_000)
        let runtime = TerminalBackendNativeBrowserRuntimeCoordinator(
            service: service,
            presentationRegistry: TerminalBackendNativeBrowserPresentationRegistry(),
            maximumConcurrentClaimCount: 16
        )

        try await runtime.claimBeforeProjection(
            authority: authority,
            surfaceIDs: surfaceIDs,
            projector: RecordingTopologyProjector()
        )

        #expect(await service.claimCallSnapshot().count == surfaceIDs.count)
        #expect(await service.maximumConcurrentClaimCount() == 16)
    }

    @Test @MainActor
    func nativeBrowserSourceCommitDispatchesWithoutDebounce() async throws {
        let authority = makeAuthority()
        let surfaceID = SurfaceID(rawValue: UUID())
        let service = RecordingNativeBrowserService(authority: authority)
        let runtime = TerminalBackendNativeBrowserRuntimeCoordinator(
            service: service,
            presentationRegistry: TerminalBackendNativeBrowserPresentationRegistry()
        )
        try await runtime.claimBeforeProjection(
            authority: authority,
            surfaceIDs: [surfaceID],
            projector: RecordingTopologyProjector()
        )
        runtime.projectionDidInstall(
            surfaceIDs: [surfaceID],
            projector: RecordingTopologyProjector()
        )
        let committedURL = try #require(URL(string: "https://example.com/committed"))

        runtime.browserDidCommitSourceURL(committedURL, surfaceID: surfaceID)

        #expect(await service.waitForSourceUpdateCount(1))
        #expect(await service.sourceUpdateCallSnapshot().map(\.sourceURL) == [committedURL])
    }

    @Test @MainActor
    func nativeBrowserSourceUpdatesCoalesceRedirectsOnlyWhileRequestIsInFlight() async throws {
        let authority = makeAuthority()
        let surfaceID = SurfaceID(rawValue: UUID())
        let service = RecordingNativeBrowserService(authority: authority)
        await service.setBlocksFirstSourceUpdate(true)
        let runtime = TerminalBackendNativeBrowserRuntimeCoordinator(
            service: service,
            presentationRegistry: TerminalBackendNativeBrowserPresentationRegistry()
        )
        try await runtime.claimBeforeProjection(
            authority: authority,
            surfaceIDs: [surfaceID],
            projector: RecordingTopologyProjector()
        )
        runtime.projectionDidInstall(
            surfaceIDs: [surfaceID],
            projector: RecordingTopologyProjector()
        )
        let firstURL = try #require(URL(string: "https://example.com/redirect-1"))
        let supersededURL = try #require(URL(string: "https://example.com/redirect-2"))
        let finalURL = try #require(URL(string: "https://example.com/final"))

        runtime.browserDidCommitSourceURL(firstURL, surfaceID: surfaceID)
        #expect(await service.waitForSourceUpdateCount(1))
        runtime.browserDidCommitSourceURL(supersededURL, surfaceID: surfaceID)
        runtime.browserDidCommitSourceURL(finalURL, surfaceID: surfaceID)
        await service.releaseFirstSourceUpdate()

        #expect(await service.waitForSourceUpdateCount(2))
        #expect(await service.sourceUpdateCallSnapshot().map(\.sourceURL) == [
            firstURL,
            finalURL,
        ])
    }

    @Test @MainActor
    func sixtyFifthNativeBrowserSourceUpdateFailsExplicitlyAndRecovers() async throws {
        let authority = makeAuthority()
        let surfaceIDs = (0..<65).map { _ in SurfaceID(rawValue: UUID()) }
        let service = RecordingNativeBrowserService(authority: authority)
        let recovery = NativeBrowserRecoveryCounter()
        var failures: [String] = []
        let runtime = TerminalBackendNativeBrowserRuntimeCoordinator(
            service: service,
            presentationRegistry: TerminalBackendNativeBrowserPresentationRegistry(),
            maximumPendingSourceUpdateCount: 64,
            failureReporter: { failures.append($0) },
            recoveryHandler: { [recovery] in await recovery.record() }
        )
        try await runtime.claimBeforeProjection(
            authority: authority,
            surfaceIDs: surfaceIDs,
            projector: RecordingTopologyProjector()
        )
        runtime.projectionDidInstall(
            surfaceIDs: surfaceIDs,
            projector: RecordingTopologyProjector()
        )

        for (index, surfaceID) in surfaceIDs.enumerated() {
            let sourceURL = try #require(URL(
                string: "https://example.com/source-\(index)"
            ))
            runtime.browserDidCommitSourceURL(sourceURL, surfaceID: surfaceID)
        }

        #expect(failures.count == 1)
        #expect(await recovery.waitForRecovery())
        #expect(await recovery.value() == 1)
    }

    @Test @MainActor
    func simultaneousNativeBrowserLeaseFailuresStartOneFrontendRecoveryGeneration() async throws {
        let authority = makeAuthority()
        let surfaceIDs = [SurfaceID(rawValue: UUID()), SurfaceID(rawValue: UUID())]
        let service = RecordingNativeBrowserService(authority: authority)
        await service.setFailsSourceUpdates(true)
        let client = TerminalBackendClientCoordinator(
            readinessProvider: { .backendUnavailable },
            sessionFactory: { _ in fatalError("unavailable readiness must not create a session") },
            reconnectPolicy: .immediate
        )
        let runtime = TerminalBackendNativeBrowserRuntimeCoordinator(
            service: service,
            presentationRegistry: TerminalBackendNativeBrowserPresentationRegistry(),
            recoveryHandler: { [client] in
                await client.recoverFrontendConnection()
            }
        )
        try await runtime.claimBeforeProjection(
            authority: authority,
            surfaceIDs: surfaceIDs,
            projector: RecordingTopologyProjector()
        )
        runtime.projectionDidInstall(
            surfaceIDs: surfaceIDs,
            projector: RecordingTopologyProjector()
        )
        let firstURL = try #require(URL(string: "https://example.com/failed-1"))
        let secondURL = try #require(URL(string: "https://example.com/failed-2"))

        runtime.browserDidCommitSourceURL(firstURL, surfaceID: surfaceIDs[0])
        runtime.browserDidCommitSourceURL(secondURL, surfaceID: surfaceIDs[1])
        #expect(await service.waitForSourceUpdateCount(2))
        for _ in 0..<200 {
            if await client.debugFrontendRecoveryStartCount > 0 { break }
            await Task.yield()
        }

        #expect(await client.debugFrontendRecoveryStartCount == 1)
        await client.disconnectFrontend()
    }

    @Test @MainActor
    func clientBrowserUUIDCollisionCannotMasqueradeAsCanonicalEndpoint() throws {
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: makeProjectionComposition()
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.tabs.first)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let browser = try #require(workspace.newBrowserSurface(
            inPane: pane,
            focus: false,
            creationPolicy: .restoration
        ))
        let terminalID = UUID()
        let canonicalPaneID = UUID()
        let canonicalPane = CanonicalPane(
            id: 1,
            uuid: CmuxTerminalBackend.PaneID(rawValue: canonicalPaneID),
            name: nil,
            tabs: [
                makeSurface(id: 1, uuid: terminalID, name: "terminal"),
                CanonicalSurface(
                    id: 2,
                    uuid: SurfaceID(rawValue: browser.id),
                    kind: "browser",
                    name: "browser",
                    browserEndpoint: CanonicalBrowserEndpoint(
                        transport: .cmuxdPNGFrameStreamV1,
                        source: .launched,
                        frontendProjection: .frontendOptional
                    )
                ),
            ]
        )
        let canonical = CanonicalWorkspace(
            id: 1,
            uuid: WorkspaceID(rawValue: workspace.id),
            name: "mixed",
            screens: [CanonicalScreen(
                id: 1,
                uuid: ScreenID(rawValue: UUID()),
                name: nil,
                layout: .leaf(pane: 1, paneUUID: canonicalPane.uuid),
                panes: [canonicalPane]
            )]
        )

        let originalPanelIDs = Set(workspace.panels.keys)
        #expect(throws: TerminalBackendBrowserEndpointError.clientOverlayCollision(
            surfaceID: browser.id
        )) {
            try manager.installCanonicalTopology(try makeSnapshot(
                authority: makeAuthority(),
                revision: 1,
                workspaces: [canonical]
            ))
        }

        #expect(manager.tabs.first === workspace)
        #expect(Set(workspace.panels.keys) == originalPanelIDs)
        #expect(workspace.panels[browser.id] === browser)
    }

    @Test @MainActor
    func optionalCanonicalBrowserDoesNotBlockSiblingTerminalProjection() throws {
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: makeProjectionComposition()
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.tabs.first)
        let browserID = UUID()
        let terminalID = UUID()
        let browserPaneID = CmuxTerminalBackend.PaneID(rawValue: UUID())
        let terminalPaneID = CmuxTerminalBackend.PaneID(rawValue: UUID())
        let browser = makeBrowserSurface(id: 1, uuid: browserID)
        let terminal = makeSurface(id: 2, uuid: terminalID, name: "terminal")
        let canonical = CanonicalWorkspace(
            id: 1,
            uuid: WorkspaceID(rawValue: workspace.id),
            name: "mixed",
            screens: [CanonicalScreen(
                id: 1,
                uuid: ScreenID(rawValue: UUID()),
                name: nil,
                layout: .split(
                    direction: .right,
                    ratio: 0.4,
                    first: .leaf(pane: 1, paneUUID: browserPaneID),
                    second: .leaf(pane: 2, paneUUID: terminalPaneID)
                ),
                panes: [
                    CanonicalPane(
                        id: 1,
                        uuid: browserPaneID,
                        name: nil,
                        tabs: [browser]
                    ),
                    CanonicalPane(
                        id: 2,
                        uuid: terminalPaneID,
                        name: nil,
                        tabs: [terminal]
                    ),
                ]
            )]
        )

        try manager.installCanonicalTopology(try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [canonical]
        ))

        let projected = try #require(manager.tabs.first)
        #expect(projected.panels[terminalID] is TerminalPanel)
        #expect(projected.panels[browserID] == nil)
        #expect(projected.bonsplitController.allPaneIds.map(\.id) == [terminalPaneID.rawValue])
    }

    @Test @MainActor
    func browserDescriptorWithoutOptionalProjectionStillFailsClosed() throws {
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: makeProjectionComposition()
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let authority = makeAuthority()
        let browserID = UUID()
        let surface = CanonicalSurface(
            id: 1,
            uuid: SurfaceID(rawValue: browserID),
            kind: "browser",
            name: "browser",
            browserEndpoint: CanonicalBrowserEndpoint(
                transport: .cmuxdPNGFrameStreamV1,
                source: .launched
            )
        )
        let canonical = makeBrowserWorkspace(workspaceID: UUID(), surface: surface)

        #expect(throws: TerminalBackendBrowserEndpointError.unsupportedContentTransport(
            TerminalBackendBrowserEndpointIdentity(
                authority: authority,
                surfaceHandle: surface.id,
                surfaceID: surface.uuid,
                transport: .cmuxdPNGFrameStreamV1
            )
        )) {
            try manager.installCanonicalTopology(try makeSnapshot(
                authority: authority,
                revision: 1,
                workspaces: [canonical]
            ))
        }
    }

    @Test @MainActor
    func browserOnlyCanonicalWorkspaceRetainsClientOverlayNamespace() throws {
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: makeProjectionComposition()
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.tabs.first)
        let terminalID = try #require(workspace.focusedPanelId)
        let pane = try #require(workspace.paneId(forPanelId: terminalID))
        let overlay = try #require(workspace.newBrowserSurface(
            inPane: pane,
            focus: false,
            creationPolicy: .restoration
        ))
        let canonicalBrowser = makeBrowserSurface(id: 1, uuid: UUID())

        try manager.installCanonicalTopology(try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [makeBrowserWorkspace(
                workspaceID: workspace.id,
                surface: canonicalBrowser
            )]
        ))

        #expect(manager.tabs.first === workspace)
        #expect(workspace.panels[terminalID] == nil)
        #expect(workspace.panels[overlay.id] === overlay)
        #expect(workspace.panels[canonicalBrowser.uuid.rawValue] == nil)
    }

    @Test @MainActor
    func dormantCanonicalBrowserDescriptorStaysValueOnly() throws {
        let factory = RecordingBrowserEndpointFactory()
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: makeProjectionComposition(
                browserEndpointFactory: factory
            )
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.tabs.first)
        let terminalID = UUID()
        let browserID = UUID()
        let selectedScreen = makeScreen(surfaceIDs: [terminalID])
        let dormantPaneID = CmuxTerminalBackend.PaneID(rawValue: UUID())
        let dormantScreen = CanonicalScreen(
            id: 2,
            uuid: ScreenID(rawValue: UUID()),
            name: "dormant",
            layout: .leaf(pane: 2, paneUUID: dormantPaneID),
            panes: [CanonicalPane(
                id: 2,
                uuid: dormantPaneID,
                name: nil,
                tabs: [makeBrowserSurface(id: 2, uuid: browserID)]
            )]
        )
        let canonical = CanonicalWorkspace(
            id: 1,
            uuid: WorkspaceID(rawValue: workspace.id),
            name: "mixed screens",
            screens: [selectedScreen, dormantScreen]
        )

        try manager.installCanonicalTopology(try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [canonical]
        ))

        let projected = try #require(manager.tabs.first)
        #expect(projected.panels[terminalID] is TerminalPanel)
        #expect(projected.panels[browserID] == nil)
        #expect(factory.validatedEndpoints.isEmpty)
        #expect(factory.materializedEndpoints.isEmpty)
    }

    @Test @MainActor
    func projectionInstallsCanonicalPaneIDsTreeRatioAndTabOrder() throws {
        let composition = makeProjectionComposition()
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: composition
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspaceID = UUID()
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let thirdSurfaceID = UUID()
        let firstPane = CanonicalPane(
            id: 1,
            uuid: CmuxTerminalBackend.PaneID(rawValue: firstPaneID),
            name: nil,
            tabs: [
                makeSurface(id: 1, uuid: firstSurfaceID, name: "one"),
                makeSurface(id: 2, uuid: secondSurfaceID, name: "two"),
            ]
        )
        let secondPane = CanonicalPane(
            id: 2,
            uuid: CmuxTerminalBackend.PaneID(rawValue: secondPaneID),
            name: nil,
            tabs: [makeSurface(id: 3, uuid: thirdSurfaceID, name: "three")]
        )
        let canonicalWorkspace = CanonicalWorkspace(
            id: 1,
            uuid: WorkspaceID(rawValue: workspaceID),
            name: "split",
            screens: [CanonicalScreen(
                id: 1,
                uuid: ScreenID(rawValue: UUID()),
                name: nil,
                layout: .split(
                    direction: .right,
                    ratio: 0.3,
                    first: .leaf(pane: 1, paneUUID: firstPane.uuid),
                    second: .leaf(pane: 2, paneUUID: secondPane.uuid)
                ),
                panes: [firstPane, secondPane]
            )]
        )

        try manager.installCanonicalTopology(try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [canonicalWorkspace]
        ))

        let workspace = try #require(manager.tabs.first)
        #expect(Set(workspace.bonsplitController.allPaneIds.map(\.id)) == [firstPaneID, secondPaneID])
        let firstLocalPane = Bonsplit.PaneID(id: firstPaneID)
        #expect(
            workspace.bonsplitController.tabs(inPane: firstLocalPane).compactMap {
                workspace.panelIdFromSurfaceId($0.id)
            } == [firstSurfaceID, secondSurfaceID]
        )
        guard case .split(let split) = workspace.bonsplitController.treeSnapshot() else {
            Issue.record("Expected canonical split root")
            return
        }
        #expect(split.orientation == "horizontal")
        #expect(abs(split.dividerPosition - 0.3) < 0.0001)
    }

    @Test @MainActor
    func backendModeLocksLocalDividerMutationWhileEmbeddedModeRetainsIt() throws {
        var failures: [String] = []
        let backendComposition = makeProjectionComposition {
            failures.append($0)
        }
        let backendManager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: backendComposition
        )
        defer { backendManager.tabs.forEach { $0.teardownAllPanels() } }
        let backendWorkspace = try #require(backendManager.tabs.first)
        let backendPanelID = try #require(backendWorkspace.focusedPanelId)
        backendWorkspace.isApplyingCanonicalTopologyProjection = true
        #expect(backendWorkspace.newTerminalSplit(
            from: backendPanelID,
            orientation: .horizontal,
            focus: false,
            initialDividerPosition: 0.25
        ) != nil)
        backendWorkspace.isApplyingCanonicalTopologyProjection = false
        let backendTreeBefore = backendWorkspace.bonsplitController.treeSnapshot()

        #expect(backendWorkspace.bonsplitController.configuration.allowDividerResizing == false)
        #expect(backendManager.equalizeSplits(tabId: backendWorkspace.id) == false)
        #expect(backendWorkspace.bonsplitController.treeSnapshot() == backendTreeBefore)
        #expect(failures.contains(where: { $0.contains(TerminalBackendTopologyMutation.changeSplitRatio.rawValue) }))

        let embeddedManager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: .embedded()
        )
        defer { embeddedManager.tabs.forEach { $0.teardownAllPanels() } }
        let embeddedWorkspace = try #require(embeddedManager.tabs.first)
        let embeddedPanelID = try #require(embeddedWorkspace.focusedPanelId)
        #expect(embeddedWorkspace.newTerminalSplit(
            from: embeddedPanelID,
            orientation: .horizontal,
            focus: false,
            initialDividerPosition: 0.25
        ) != nil)

        #expect(embeddedWorkspace.bonsplitController.configuration.allowDividerResizing == true)
        #expect(embeddedManager.equalizeSplits(tabId: embeddedWorkspace.id))
        guard case .split(let embeddedSplit) = embeddedWorkspace.bonsplitController.treeSnapshot() else {
            Issue.record("Expected embedded split root")
            return
        }
        #expect(abs(embeddedSplit.dividerPosition - 0.5) < 0.0001)
    }

    @Test @MainActor
    func everyWorkspaceReorderEntrypointLeavesBackendProjectionUnchanged() throws {
        var failures: [String] = []
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            terminalClientComposition: makeProjectionComposition {
                failures.append($0)
            }
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let firstWorkspaceID = UUID()
        let secondWorkspaceID = UUID()
        try manager.installCanonicalTopology(try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [
                makeWorkspace(workspaceID: firstWorkspaceID, surfaceIDs: [UUID()]),
                makeWorkspace(
                    workspaceID: secondWorkspaceID,
                    workspaceNumber: 2,
                    screenNumber: 2,
                    paneNumber: 2,
                    firstSurfaceNumber: 2,
                    surfaceIDs: [UUID()]
                ),
            ]
        ))
        let canonicalOrder = manager.tabs.map(\.id)

        manager.moveTabToTop(secondWorkspaceID)
        manager.moveTabsToTop([secondWorkspaceID])
        manager.moveTabToTopForNotification(secondWorkspaceID)
        #expect(manager.reorderWorkspace(tabId: secondWorkspaceID, toIndex: 0) == false)
        #expect(manager.reorderWorkspace(tabId: secondWorkspaceID, before: firstWorkspaceID) == false)
        let batchResult = manager.reorderWorkspaces(
            orderedWorkspaceIds: [secondWorkspaceID, firstWorkspaceID]
        )

        #expect(manager.tabs.map(\.id) == canonicalOrder)
        #expect(try batchResult.get().isEmpty)
        #expect(failures.count == 6)
        #expect(failures.allSatisfy {
            $0.contains(TerminalBackendTopologyMutation.reorderWorkspace.rawValue)
        })
    }

    @Test @MainActor
    func appRestoreCompletionHydratesTwoWindowsBeforeFirstCanonicalAssignment() async throws {
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let firstWorkspaceID = UUID()
        let secondWorkspaceID = UUID()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let firstWorkspace = makeWorkspace(
            workspaceID: firstWorkspaceID,
            surfaceIDs: [firstSurfaceID]
        )
        let secondWorkspace = makeWorkspace(
            workspaceID: secondWorkspaceID,
            workspaceNumber: 2,
            screenNumber: 2,
            paneNumber: 2,
            firstSurfaceNumber: 2,
            surfaceIDs: [secondSurfaceID]
        )
        let store = RecordingProjectionStateStore(states: [
            BackendProjectionState(
                logicalPresentationID: firstWindowID,
                generation: 3,
                claimID: nil,
                claimedProcessInstanceID: nil,
                workspaces: [BackendProjectionWorkspaceState(
                    workspaceID: firstWorkspace.uuid,
                    selectedScreenID: firstWorkspace.screens[0].uuid
                )]
            ),
            BackendProjectionState(
                logicalPresentationID: secondWindowID,
                generation: 5,
                claimID: nil,
                claimedProcessInstanceID: nil,
                workspaces: [BackendProjectionWorkspaceState(
                    workspaceID: secondWorkspace.uuid,
                    selectedScreenID: secondWorkspace.screens[0].uuid
                )]
            ),
        ])
        let first = RecordingTopologyProjector()
        let second = RecordingTopologyProjector()
        let registry = TerminalBackendTopologyProjectionRegistry(
            projectionStateStore: store
        )
        registry.register(first, presentationID: firstWindowID, isPrimary: true)
        registry.register(second, presentationID: secondWindowID, isPrimary: false)
        let appDelegate = AppDelegate()
        appDelegate.debugCompleteTerminalBackendSessionRestoreForTesting(
            projectionRegistry: registry
        )
        #expect(!appDelegate.isApplyingSessionRestore)
        let snapshot = try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [firstWorkspace, secondWorkspace]
        )
        let structural = try TerminalBackendTopologyProjectionPlan(topology: snapshot.topology)

        #expect(throws: TerminalBackendTopologyProjectionError.self) {
            _ = try registry.resolvePresentationPlan(structural)
        }
        await settle()

        let resolved = try registry.resolvePresentationPlan(structural)
        try registry.installCanonicalTopology(snapshot, plan: resolved)
        #expect(first.installedPlans.last?.workspaces.map {
            $0.canonical.uuid.rawValue
        } == [firstWorkspaceID])
        #expect(second.installedPlans.last?.workspaces.map {
            $0.canonical.uuid.rawValue
        } == [secondWorkspaceID])
    }

    @Test @MainActor
    func crossWindowMovePersistsAtomicallyAndRestoresIntoSameWindowIDs() async throws {
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let workspace = makeWorkspace(workspaceID: workspaceID, surfaceIDs: [surfaceID])
        let snapshot = try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: [workspace]
        )
        let structural = try TerminalBackendTopologyProjectionPlan(topology: snapshot.topology)
        let placement = TerminalBackendTopologyPlacement(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        let store = RecordingProjectionStateStore()
        let first = RecordingTopologyProjector(legacyPlacements: [placement])
        let second = RecordingTopologyProjector()
        let registry = TerminalBackendTopologyProjectionRegistry(
            projectionStateStore: store
        )
        registry.register(first, presentationID: firstWindowID, isPrimary: true)
        registry.register(second, presentationID: secondWindowID, isPrimary: false)
        registry.startupRestoreDidFinish()
        await settle()
        try registry.installCanonicalTopology(
            snapshot,
            plan: registry.resolvePresentationPlan(structural)
        )
        await settle()

        let transfer = try registry.prepareWorkspaceOwnershipTransfer(
            workspaceID: workspaceID,
            from: first,
            to: second
        )
        try transfer.commit()
        first.presentedPlacements = []
        second.presentedPlacements = [placement]
        try registry.installCanonicalTopology(
            snapshot,
            plan: registry.resolvePresentationPlan(structural)
        )
        await settle()

        let persisted = await store.stateByPresentationID()
        #expect(persisted[firstWindowID]?.workspaces.isEmpty == true)
        #expect(persisted[secondWindowID]?.workspaces.map(\.workspaceID.rawValue) == [workspaceID])
        #expect(await store.updateBatchCount() == 2)

        let restoredFirst = RecordingTopologyProjector()
        let restoredSecond = RecordingTopologyProjector(legacyPlacements: [placement])
        let restored = TerminalBackendTopologyProjectionRegistry(
            projectionStateStore: store
        )
        restored.register(restoredFirst, presentationID: firstWindowID, isPrimary: true)
        restored.register(restoredSecond, presentationID: secondWindowID, isPrimary: false)
        restored.startupRestoreDidFinish()
        await settle()
        try restored.installCanonicalTopology(
            snapshot,
            plan: restored.resolvePresentationPlan(structural)
        )

        #expect(restoredFirst.installedPlans.last?.workspaces.isEmpty == true)
        #expect(restoredSecond.installedPlans.last?.workspaces.map {
            $0.canonical.uuid.rawValue
        } == [workspaceID])
    }

    @Test @MainActor
    func genericUnregisterRetainsProjectionButExplicitWindowCloseDeletesIt() async throws {
        let windowID = UUID()
        let store = RecordingProjectionStateStore()
        let first = RecordingTopologyProjector()
        let registry = TerminalBackendTopologyProjectionRegistry(
            projectionStateStore: store
        )
        registry.register(first, presentationID: windowID, isPrimary: true)
        registry.startupRestoreDidFinish()
        await settle()

        registry.unregister(first)
        #expect(await store.stateByPresentationID()[windowID] != nil)

        let restored = RecordingTopologyProjector()
        registry.register(restored, presentationID: windowID, isPrimary: true)
        await settle()
        registry.closeProjection(presentationID: windowID)
        registry.unregister(restored)
        await settle()
        #expect(await store.stateByPresentationID()[windowID] == nil)
    }

    @Test @MainActor
    func explicitWindowCloseRetriesAfterBackendReconnectSignal() async throws {
        let windowID = UUID()
        let store = RecordingProjectionStateStore()
        let projector = RecordingTopologyProjector()
        let registry = TerminalBackendTopologyProjectionRegistry(
            projectionStateStore: store
        )
        registry.register(projector, presentationID: windowID, isPrimary: true)
        registry.startupRestoreDidFinish()
        await settle()
        #expect(await store.stateByPresentationID()[windowID] != nil)

        await store.setAvailable(false)
        registry.closeProjection(presentationID: windowID)
        registry.unregister(projector)
        await settle()
        #expect(await store.stateByPresentationID()[windowID] != nil)

        await store.setAvailable(true)
        let snapshot = try makeSnapshot(
            authority: makeAuthority(),
            revision: 1,
            workspaces: []
        )
        let structural = try TerminalBackendTopologyProjectionPlan(
            topology: snapshot.topology
        )
        #expect(throws: TerminalBackendTopologyProjectionError.self) {
            _ = try registry.resolvePresentationPlan(structural)
        }
        await settle()

        #expect(await store.stateByPresentationID()[windowID] == nil)
        _ = try registry.resolvePresentationPlan(structural)
    }

    @Test @MainActor
    func remoteTmuxRestartAdoptsCanonicalProducerAndSurfaceIdentities() async throws {
        let authority = makeAuthority()
        let producerID = UUID()
        let workspaceID = UUID()
        let outerSurfaceID = SurfaceID(rawValue: UUID())
        let nestedSurfaceID = SurfaceID(rawValue: UUID())
        let source = BackendRemoteTmuxProducerSource(
            destination: "private.example",
            port: 2222,
            identityFile: "/private/key",
            sessionName: "agents"
        )
        let outerProvenance = CanonicalExternalTerminalProvenance(
            producerID: producerID,
            tmuxSessionID: 7,
            tmuxWindowID: 11,
            tmuxPaneID: 13,
            presentationRole: .workspaceTab
        )
        let nestedProvenance = CanonicalExternalTerminalProvenance(
            producerID: producerID,
            tmuxSessionID: 7,
            tmuxWindowID: 11,
            tmuxPaneID: 17,
            presentationRole: .nestedPane
        )
        let canonicalPaneID = CmuxTerminalBackend.PaneID(rawValue: UUID())
        let topology = try CanonicalTopology(workspaces: [CanonicalWorkspace(
            id: 1,
            uuid: WorkspaceID(rawValue: workspaceID),
            name: "remote tmux",
            screens: [CanonicalScreen(
                id: 1,
                uuid: ScreenID(rawValue: UUID()),
                name: nil,
                layout: .leaf(pane: 1, paneUUID: canonicalPaneID),
                panes: [CanonicalPane(
                    id: 1,
                    uuid: canonicalPaneID,
                    name: nil,
                    tabs: [
                        CanonicalSurface(
                            id: 1,
                            uuid: outerSurfaceID,
                            kind: "terminal",
                            name: "window",
                            externalTerminalProvenance: outerProvenance
                        ),
                        CanonicalSurface(
                            id: 2,
                            uuid: nestedSurfaceID,
                            kind: "terminal",
                            name: "nested pane",
                            externalTerminalProvenance: nestedProvenance
                        ),
                    ]
                )]
            )]
        )])
        let plan = try TerminalBackendTopologyProjectionPlan(topology: topology)
        let service = RecordingExternalTerminalService(
            authority: authority,
            producerSources: [producerID: source]
        )
        let registry = TerminalBackendRemoteTmuxSurfaceRegistry(
            service: service,
            producerSourceService: service
        )

        try await registry.claimBeforeProjection(authority: authority, plan: plan)
        #expect(registry.shouldProjectCanonicalSurface(outerSurfaceID))
        #expect(!registry.shouldProjectCanonicalSurface(nestedSurfaceID))

        let projector = RecordingTopologyProjector()
        registry.projectionDidInstall(plan: plan, projector: projector)
        #expect(projector.restoredRemoteTmuxProducers.count == 1)
        let restored = try #require(projector.restoredRemoteTmuxProducers.first)
        #expect(restored.producerID == producerID)
        #expect(restored.workspaceID == workspaceID)
        #expect(restored.tmuxSessionID == 7)
        #expect(restored.source == source)
        #expect(Set(restored.surfaces.map(\.surfaceID)) == [outerSurfaceID, nestedSurfaceID])

        let outer = try #require(registry.register(
            workspaceID: workspaceID,
            provenance: outerProvenance,
            sendKeys: { _ in true },
            requestSeed: {}
        ))
        let nested = try #require(registry.register(
            workspaceID: workspaceID,
            provenance: nestedProvenance,
            sendKeys: { _ in true },
            requestSeed: {}
        ))
        #expect(!outer.isNew)
        #expect(!nested.isNew)
        #expect(outer.surfaceID == outerSurfaceID.rawValue)
        #expect(nested.surfaceID == nestedSurfaceID.rawValue)
        #expect(outer.isProjected)
        #expect(nested.isProjected)
    }

    @MainActor
    private func makeProjectionComposition(
        failureReporter: @escaping @MainActor (String) -> Void = { _ in },
        browserEndpointFactory: (any TerminalBackendBrowserEndpointCreating)? = nil
    ) -> TerminalClientComposition {
        TerminalClientComposition(
            terminalPanelFactory: CanonicalTestTerminalPanelFactory(),
            terminalBackendTopologyMutationCoordinator: TerminalBackendTopologyMutationCoordinator(
                mutator: RejectingTopologyMutator(),
                failureReporter: failureReporter
            ),
            terminalBackendTopologyAdoptionRegistry: TerminalBackendTopologyAdoptionRegistry(),
            browserEndpointFactory: browserEndpointFactory
                ?? UnsupportedTerminalBackendBrowserEndpointFactory()
        )
    }

    @MainActor
    private func makeNativeBrowserProjectionComposition(
        service: any TerminalBackendFrontendNativeBrowserServing
    ) -> (
        composition: TerminalClientComposition,
        runtime: TerminalBackendNativeBrowserRuntimeCoordinator,
        registry: TerminalBackendNativeBrowserPresentationRegistry
    ) {
        let registry = TerminalBackendNativeBrowserPresentationRegistry()
        let runtime = TerminalBackendNativeBrowserRuntimeCoordinator(
            service: service,
            presentationRegistry: registry
        )
        let composition = TerminalClientComposition(
            terminalPanelFactory: CanonicalTestTerminalPanelFactory(),
            terminalBackendTopologyMutationCoordinator:
                TerminalBackendTopologyMutationCoordinator(
                    mutator: RejectingTopologyMutator()
                ),
            terminalBackendTopologyAdoptionRegistry:
                TerminalBackendTopologyAdoptionRegistry(),
            nativeBrowserPresentationRegistry: registry,
            nativeBrowserRuntimeCoordinator: runtime,
            browserEndpointFactory: NativeTerminalBackendBrowserEndpointFactory(
                presentationRegistry: registry,
                claimedSourceURL: { [runtime] surfaceID in
                    runtime.claimedSourceURL(surfaceID: surfaceID)
                }
            ),
            canonicalBrowserProjectionAvailable: true
        )
        return (composition, runtime, registry)
    }

    @MainActor
    private func settle() async {
        for _ in 0..<12 { await Task.yield() }
    }

    private func makeAuthority(sessionID: SessionID = SessionID(rawValue: UUID())) -> BackendAuthority {
        BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: sessionID
        )
    }

    private func makeSurfacePlacement(
        authority: BackendAuthority,
        revision: UInt64,
        workspaceID: UUID,
        surfaceID: UUID
    ) throws -> BackendSurfacePlacement {
        let data = try JSONSerialization.data(withJSONObject: [
            "request_id": UUID().uuidString.lowercased(),
            "daemon_instance_id": authority.daemonInstanceID.rawValue.uuidString.lowercased(),
            "session_id": authority.sessionID.rawValue.uuidString.lowercased(),
            "base_revision": revision - 1,
            "revision": revision,
            "replayed": false,
            "surface": 1,
            "surface_uuid": surfaceID.uuidString.lowercased(),
            "pane": 1,
            "pane_uuid": UUID().uuidString.lowercased(),
            "screen": 1,
            "screen_uuid": UUID().uuidString.lowercased(),
            "workspace": 1,
            "workspace_uuid": workspaceID.uuidString.lowercased(),
        ])
        return try JSONDecoder().decode(BackendSurfacePlacement.self, from: data)
    }

    private func makeSnapshot(
        authority: BackendAuthority,
        revision: UInt64,
        workspaces: [CanonicalWorkspace]
    ) throws -> TopologySnapshot {
        TopologySnapshot(
            authority: authority,
            revision: revision,
            topology: try CanonicalTopology(workspaces: workspaces)
        )
    }

    private func makeWorkspace(
        workspaceID: UUID = UUID(),
        workspaceName: String = "canonical",
        workspaceNumber: UInt64 = 1,
        screenNumber: UInt64 = 1,
        paneNumber: UInt64 = 1,
        paneID: UUID? = nil,
        firstSurfaceNumber: UInt64 = 1,
        surfaceIDs: [UUID]
    ) -> CanonicalWorkspace {
        CanonicalWorkspace(
            id: workspaceNumber,
            uuid: WorkspaceID(rawValue: workspaceID),
            name: workspaceName,
            screens: [makeScreen(
                surfaceIDs: surfaceIDs,
                screenNumber: screenNumber,
                paneNumber: paneNumber,
                paneID: paneID,
                firstSurfaceNumber: firstSurfaceNumber
            )]
        )
    }

    private func makeScreen(
        surfaceIDs: [UUID],
        screenNumber: UInt64 = 1,
        paneNumber: UInt64 = 1,
        paneID: UUID? = nil,
        firstSurfaceNumber: UInt64 = 1
    ) -> CanonicalScreen {
        let paneUUID = CmuxTerminalBackend.PaneID(rawValue: paneID ?? UUID())
        return CanonicalScreen(
            id: screenNumber,
            uuid: ScreenID(rawValue: UUID()),
            name: nil,
            layout: .leaf(pane: paneNumber, paneUUID: paneUUID),
            panes: [CanonicalPane(
                id: paneNumber,
                uuid: paneUUID,
                name: nil,
                tabs: surfaceIDs.enumerated().map { index, surfaceID in
                    CanonicalSurface(
                        id: firstSurfaceNumber + UInt64(index),
                        uuid: SurfaceID(rawValue: surfaceID),
                        kind: "terminal",
                        name: "surface \(index + 1)"
                    )
                }
            )]
        )
    }

    private func makeMixedWorkspace(
        workspaceID: UUID,
        workspaceNumber: UInt64,
        screenNumber: UInt64,
        paneNumber: UInt64,
        paneID: UUID,
        surfaces: [CanonicalSurface]
    ) -> CanonicalWorkspace {
        let canonicalPaneID = CmuxTerminalBackend.PaneID(rawValue: paneID)
        return CanonicalWorkspace(
            id: workspaceNumber,
            uuid: WorkspaceID(rawValue: workspaceID),
            name: "canonical",
            screens: [CanonicalScreen(
                id: screenNumber,
                uuid: ScreenID(rawValue: UUID()),
                name: nil,
                layout: .leaf(pane: paneNumber, paneUUID: canonicalPaneID),
                panes: [CanonicalPane(
                    id: paneNumber,
                    uuid: canonicalPaneID,
                    name: nil,
                    tabs: surfaces
                )]
            )]
        )
    }

    private func makeSurface(id: UInt64, uuid: UUID, name: String) -> CanonicalSurface {
        CanonicalSurface(
            id: id,
            uuid: SurfaceID(rawValue: uuid),
            kind: "terminal",
            name: name
        )
    }

    private func makeBrowserSurface(id: UInt64, uuid: UUID) -> CanonicalSurface {
        CanonicalSurface(
            id: id,
            uuid: SurfaceID(rawValue: uuid),
            kind: "browser",
            name: "browser",
            browserEndpoint: CanonicalBrowserEndpoint(
                transport: .cmuxdPNGFrameStreamV1,
                source: .launched,
                frontendProjection: .frontendOptional
            )
        )
    }

    private func makeRequiredBrowserSurface(
        id: UInt64,
        uuid: UUID
    ) -> CanonicalSurface {
        CanonicalSurface(
            id: id,
            uuid: SurfaceID(rawValue: uuid),
            kind: "browser",
            name: "browser",
            browserEndpoint: CanonicalBrowserEndpoint(
                transport: .cmuxdPNGFrameStreamV1,
                source: .launched
            )
        )
    }

    private func makeFrontendNativeBrowserSurface(
        id: UInt64,
        uuid: UUID
    ) -> CanonicalSurface {
        CanonicalSurface(
            id: id,
            uuid: SurfaceID(rawValue: uuid),
            kind: "browser",
            name: "browser",
            browserEndpoint: CanonicalBrowserEndpoint(
                transport: .frontendNativeV1,
                source: .launched
            )
        )
    }

    private func makeBrowserWorkspace(
        workspaceID: UUID,
        surface: CanonicalSurface
    ) -> CanonicalWorkspace {
        let paneID = CmuxTerminalBackend.PaneID(rawValue: UUID())
        return CanonicalWorkspace(
            id: 1,
            uuid: WorkspaceID(rawValue: workspaceID),
            name: "browser",
            screens: [CanonicalScreen(
                id: 1,
                uuid: ScreenID(rawValue: UUID()),
                name: nil,
                layout: .leaf(pane: 1, paneUUID: paneID),
                panes: [CanonicalPane(
                    id: 1,
                    uuid: paneID,
                    name: nil,
                    tabs: [surface]
                )]
            )]
        )
    }
}

@MainActor
private final class RecordingBrowserEndpointFactory: TerminalBackendBrowserEndpointCreating {
    private(set) var validatedEndpoints: [TerminalBackendBrowserEndpoint] = []
    private(set) var materializedEndpoints: [TerminalBackendBrowserEndpoint] = []

    func validate(_ endpoint: TerminalBackendBrowserEndpoint) throws {
        validatedEndpoints.append(endpoint)
    }

    func makeBrowserPanel(
        endpoint: TerminalBackendBrowserEndpoint,
        workspaceID: UUID
    ) throws -> BrowserPanel {
        materializedEndpoints.append(endpoint)
        return BrowserPanel(
            id: endpoint.identity.surfaceID.rawValue,
            workspaceId: workspaceID,
            endpointProvenance: .backend(endpoint.identity),
            renderInitialNavigation: false
        )
    }
}

@MainActor
private final class RecordingTopologyProjector: TerminalBackendTopologyProjecting {
    var legacyPlacements: Set<TerminalBackendTopologyPlacement>
    var presentedPlacements: Set<TerminalBackendTopologyPlacement>
    private(set) var legacyReadCount = 0
    private(set) var installedSnapshots: [TopologySnapshot] = []
    private(set) var installedPlans: [TerminalBackendTopologyProjectionPlan] = []
    private(set) var commitAttemptRevisions: [UInt64] = []
    private(set) var restoredRemoteTmuxProducers: [
        TerminalBackendRemoteTmuxProducerProjection
    ] = []
    private let failPreparation: Bool
    private let failCommitRevisions: Set<UInt64>
    private var remainingTransientCommitFailures: [UInt64: Int]

    init(
        legacyPlacements: Set<TerminalBackendTopologyPlacement> = [],
        allPresentationPlacements: Set<TerminalBackendTopologyPlacement>? = nil,
        failPreparation: Bool = false,
        failCommitRevisions: Set<UInt64> = [],
        transientCommitFailures: [UInt64: Int] = [:]
    ) {
        self.legacyPlacements = legacyPlacements
        self.presentedPlacements = allPresentationPlacements ?? legacyPlacements
        self.failPreparation = failPreparation
        self.failCommitRevisions = failCommitRevisions
        self.remainingTransientCommitFailures = transientCommitFailures
    }

    func presentationWorkspaceIDs() -> Set<UUID> {
        Set(presentedPlacements.map(\.workspaceID))
    }

    func allPresentationPlacements() -> Set<TerminalBackendTopologyPlacement> {
        presentedPlacements
    }

    func legacyTerminalPlacements() -> Set<TerminalBackendTopologyPlacement> {
        legacyReadCount += 1
        return legacyPlacements
    }

    func restoreRemoteTmuxProducer(
        _ projection: TerminalBackendRemoteTmuxProducerProjection
    ) -> Bool {
        restoredRemoteTmuxProducers.append(projection)
        return true
    }

    func prepareCanonicalTopology(
        _ snapshot: TopologySnapshot,
        plan: TerminalBackendTopologyProjectionPlan
    ) throws -> TerminalBackendTopologyPreparedProjection {
        if failPreparation {
            throw ProjectionTestError()
        }
        return TerminalBackendTopologyPreparedProjection(
            commit: { [weak self] in
                guard let self else { return }
                self.commitAttemptRevisions.append(snapshot.revision)
                if self.failCommitRevisions.contains(snapshot.revision) {
                    throw ProjectionTestError()
                }
                if let remaining = self.remainingTransientCommitFailures[snapshot.revision],
                   remaining > 0 {
                    self.remainingTransientCommitFailures[snapshot.revision] = remaining - 1
                    throw ProjectionTestError()
                }
                self.installedPlans.append(plan)
                self.installedSnapshots.append(snapshot)
            },
            rollback: { [weak self] in
                guard let self,
                      self.installedPlans.last == plan,
                      self.installedSnapshots.last == snapshot else { return }
                self.installedPlans.removeLast()
                self.installedSnapshots.removeLast()
            }
        )
    }
}

private struct ProjectionTestError: Error {}

/// Keeps topology projection tests on the production ownership boundary
/// without opening sockets or starting renderer workers.
@MainActor
private final class CanonicalTestTerminalPanelFactory: TerminalPanelCreating {
    func makeTerminalPanel(_ request: TerminalPanelCreationRequest) -> TerminalPanel {
        TerminalPanel(
            externalRequest: request,
            presentationDependencies: GhosttyApp.terminalSurfacePresentationDependencies,
            externalRuntime: CanonicalTestTerminalRuntime()
        )
    }
}

@MainActor
private final class CanonicalTestTerminalRuntime: TerminalExternalRuntime {
    let snapshot = TerminalExternalRuntimeSnapshot(lifecycle: .live)
    private var nextSequence: UInt64 = 1

    func attachPresentation(
        _ presentation: TerminalExternalPresentation
    ) -> any TerminalExternalPresentationLease {
        _ = presentation
        return CanonicalTestTerminalPresentationLease()
    }

    func enqueue(
        _ mutation: TerminalExternalRuntimeMutation
    ) -> TerminalExternalIngressResult {
        _ = mutation
        defer { nextSequence += 1 }
        return .accepted(sequence: nextSequence)
    }

    func readScreenText(_ request: TerminalExternalScreenTextRequest) async -> String? {
        _ = request
        return nil
    }

    func readSelection() async -> TerminalExternalSelection? {
        nil
    }
}

private final class CanonicalTestTerminalPresentationLease:
    TerminalExternalPresentationLease,
    @unchecked Sendable
{
    nonisolated func detach() {}
}

private actor RecordingProjectionStateStore: TerminalBackendProjectionStateServing {
    private let processInstanceID = UUID()
    private var states: [UUID: BackendProjectionState]
    private var batchCount = 0
    private var isAvailable = true

    init(states: [BackendProjectionState] = []) {
        self.states = Dictionary(uniqueKeysWithValues: states.map {
            ($0.logicalPresentationID, $0)
        })
    }

    func claimProjectionState(
        logicalPresentationID: UUID
    ) async throws -> BackendProjectionState {
        guard isAvailable else { throw ProjectionTestError() }
        let prior = states[logicalPresentationID]
        let claimed = BackendProjectionState(
            logicalPresentationID: logicalPresentationID,
            generation: (prior?.generation ?? 0) + 1,
            claimID: UUID(),
            claimedProcessInstanceID: processInstanceID,
            workspaces: prior?.workspaces ?? []
        )
        states[logicalPresentationID] = claimed
        return claimed
    }

    func updateProjectionStates(
        _ projections: [BackendProjectionStateUpdate]
    ) async throws -> [BackendProjectionState] {
        guard isAvailable else { throw ProjectionTestError() }
        var candidate = states
        var owners: [UUID: UUID] = [:]
        for update in projections {
            guard let current = candidate[update.logicalPresentationID],
                  current.claimID == update.claimID,
                  current.generation == update.expectedGeneration else {
                throw ProjectionTestError()
            }
            let nextGeneration = current.workspaces == update.workspaces
                ? current.generation
                : current.generation + 1
            candidate[update.logicalPresentationID] = BackendProjectionState(
                logicalPresentationID: update.logicalPresentationID,
                generation: nextGeneration,
                claimID: update.claimID,
                claimedProcessInstanceID: processInstanceID,
                workspaces: update.workspaces
            )
        }
        for state in candidate.values {
            for workspace in state.workspaces {
                guard owners.updateValue(
                    state.logicalPresentationID,
                    forKey: workspace.workspaceID.rawValue
                ) == nil else {
                    throw ProjectionTestError()
                }
            }
        }
        states = candidate
        batchCount += 1
        return try projections.map { update in
            guard let state = states[update.logicalPresentationID] else {
                throw ProjectionTestError()
            }
            return state
        }
    }

    func releaseProjectionState(
        logicalPresentationID: UUID,
        claimID: UUID,
        expectedGeneration: UInt64
    ) async throws {
        guard isAvailable else { throw ProjectionTestError() }
        guard let current = states[logicalPresentationID],
              current.claimID == claimID,
              current.generation == expectedGeneration else {
            throw ProjectionTestError()
        }
        states.removeValue(forKey: logicalPresentationID)
    }

    func listProjectionStates() async throws -> [BackendProjectionState] {
        guard isAvailable else { throw ProjectionTestError() }
        return states.values
            .sorted {
                $0.logicalPresentationID.uuidString < $1.logicalPresentationID.uuidString
            }
            .map { state in
                BackendProjectionState(
                    logicalPresentationID: state.logicalPresentationID,
                    generation: state.generation,
                    claimID: nil,
                    claimedProcessInstanceID: nil,
                    workspaces: state.workspaces
                )
            }
    }

    func stateByPresentationID() -> [UUID: BackendProjectionState] {
        states
    }

    func updateBatchCount() -> Int {
        batchCount
    }

    func setAvailable(_ available: Bool) {
        isAvailable = available
    }
}

private actor RecordingNativeBrowserService:
    TerminalBackendFrontendNativeBrowserServing
{
    struct ClaimCall: Sendable {
        let surfaceID: SurfaceID
        let requestID: UUID
        let sourceURL: URL?
    }

    struct SourceUpdateCall: Sendable {
        let surfaceID: SurfaceID
        let requestID: UUID
        let sourceURL: URL
    }

    private let authority: BackendAuthority
    private var retainedSources: [SurfaceID: URL]
    private var claimCalls: [ClaimCall] = []
    private var sourceUpdateCalls: [SourceUpdateCall] = []
    private var activeClaimCount = 0
    private var maximumActiveClaimCount = 0
    private var claimDelayNanoseconds: UInt64 = 0
    private var blocksFirstSourceUpdate = false
    private var firstSourceUpdateContinuation: CheckedContinuation<Void, Never>?
    private var failsSourceUpdates = false

    init(
        authority: BackendAuthority,
        retainedSources: [SurfaceID: URL] = [:]
    ) {
        self.authority = authority
        self.retainedSources = retainedSources
    }

    func claimFrontendNativeBrowser(
        surfaceID: SurfaceID,
        requestID: UUID,
        sourceURL: URL?
    ) async throws -> BackendFrontendNativeBrowserClaimReceipt {
        claimCalls.append(ClaimCall(
            surfaceID: surfaceID,
            requestID: requestID,
            sourceURL: sourceURL
        ))
        activeClaimCount += 1
        maximumActiveClaimCount = max(maximumActiveClaimCount, activeClaimCount)
        defer { activeClaimCount -= 1 }
        if claimDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: claimDelayNanoseconds)
        }
        let resolvedSource = retainedSources[surfaceID] ?? sourceURL
        if let resolvedSource {
            retainedSources[surfaceID] = resolvedSource
        }
        return BackendFrontendNativeBrowserClaimReceipt(
            requestID: requestID,
            daemonInstanceID: authority.daemonInstanceID,
            sessionID: authority.sessionID,
            surfaceID: surfaceID,
            ownerGeneration: 1,
            sourceURL: resolvedSource,
            replayed: false
        )
    }

    func updateFrontendNativeBrowserSource(
        surfaceID: SurfaceID,
        ownerGeneration: UInt64,
        requestID: UUID,
        sourceURL: URL
    ) async throws -> BackendFrontendNativeBrowserSourceReceipt {
        sourceUpdateCalls.append(SourceUpdateCall(
            surfaceID: surfaceID,
            requestID: requestID,
            sourceURL: sourceURL
        ))
        if blocksFirstSourceUpdate, sourceUpdateCalls.count == 1 {
            await withCheckedContinuation { continuation in
                firstSourceUpdateContinuation = continuation
            }
        }
        if failsSourceUpdates {
            throw ProjectionTestError()
        }
        retainedSources[surfaceID] = sourceURL
        return BackendFrontendNativeBrowserSourceReceipt(
            requestID: requestID,
            daemonInstanceID: authority.daemonInstanceID,
            sessionID: authority.sessionID,
            surfaceID: surfaceID,
            ownerGeneration: ownerGeneration,
            replayed: false
        )
    }

    func setClaimDelay(nanoseconds: UInt64) {
        claimDelayNanoseconds = nanoseconds
    }

    func setBlocksFirstSourceUpdate(_ blocks: Bool) {
        blocksFirstSourceUpdate = blocks
    }

    func releaseFirstSourceUpdate() {
        firstSourceUpdateContinuation?.resume()
        firstSourceUpdateContinuation = nil
    }

    func setFailsSourceUpdates(_ fails: Bool) {
        failsSourceUpdates = fails
    }

    func claimCallSnapshot() -> [ClaimCall] {
        claimCalls
    }

    func sourceUpdateCallSnapshot() -> [SourceUpdateCall] {
        sourceUpdateCalls
    }

    func maximumConcurrentClaimCount() -> Int {
        maximumActiveClaimCount
    }

    func waitForSourceUpdateCount(_ expectedCount: Int) async -> Bool {
        for _ in 0..<200 {
            if sourceUpdateCalls.count >= expectedCount { return true }
            await Task.yield()
        }
        return sourceUpdateCalls.count >= expectedCount
    }
}

private actor NativeBrowserRecoveryCounter {
    private var count = 0

    func record() {
        count += 1
    }

    func value() -> Int {
        count
    }

    func waitForRecovery() async -> Bool {
        for _ in 0..<200 {
            if count > 0 { return true }
            await Task.yield()
        }
        return count > 0
    }
}

private struct RejectingTopologyMutator: TerminalBackendTopologyMutating {
    let createWorkspacePlacement: BackendSurfacePlacement?

    init(createWorkspacePlacement: BackendSurfacePlacement? = nil) {
        self.createWorkspacePlacement = createWorkspacePlacement
    }

    private func reject<T>() throws -> T {
        throw BackendProtocolError.connectionClosed
    }

    func createWorkspace(
        requestID: UUID, workspaceID: WorkspaceID, surfaceID: SurfaceID,
        name: String?, launch: BackendTerminalLaunch, columns: UInt16?, rows: UInt16?
    ) async throws -> BackendSurfacePlacement {
        if let createWorkspacePlacement { return createWorkspacePlacement }
        return try reject()
    }

    func createTerminalTab(
        requestID: UUID, surfaceID: SurfaceID, in paneID: CmuxTerminalBackend.PaneID,
        launch: BackendTerminalLaunch, columns: UInt16?, rows: UInt16?
    ) async throws -> BackendSurfacePlacement { try reject() }

    func createBrowserWorkspace(
        requestID: UUID, workspaceID: WorkspaceID, surfaceID: SurfaceID,
        name: String?, url: URL, columns: UInt16?, rows: UInt16?
    ) async throws -> BackendSurfacePlacement { try reject() }

    func createBrowserTab(
        requestID: UUID, surfaceID: SurfaceID, in paneID: CmuxTerminalBackend.PaneID,
        url: URL, columns: UInt16?, rows: UInt16?
    ) async throws -> BackendSurfacePlacement { try reject() }

    func splitBrowserPane(
        requestID: UUID, surfaceID: SurfaceID, _ paneID: CmuxTerminalBackend.PaneID,
        direction: BackendSplitDirection, initialRatio: Float, url: URL,
        columns: UInt16?, rows: UInt16?
    ) async throws -> BackendSurfacePlacement { try reject() }

    func materializeTerminal(
        requestID: UUID, workspaceID: WorkspaceID, surfaceID: SurfaceID,
        launch: BackendTerminalLaunch, columns: UInt16?, rows: UInt16?
    ) async throws -> BackendSurfacePlacement { try reject() }

    func respawnTerminal(
        requestID: UUID, surfaceID: SurfaceID, launch: BackendTerminalLaunch,
        columns: UInt16?, rows: UInt16?
    ) async throws -> BackendSurfacePlacement { try reject() }

    func newExternalWorkspace(
        requestID: UUID, workspaceID: WorkspaceID, surfaceID: SurfaceID,
        columns: UInt16, rows: UInt16, noReflow: Bool,
        provenance: CanonicalExternalTerminalProvenance,
        producerSource: BackendRemoteTmuxProducerSource
    ) async throws -> BackendSurfacePlacement { try reject() }

    func materializeExternalTerminal(
        requestID: UUID, workspaceID: WorkspaceID, surfaceID: SurfaceID,
        columns: UInt16, rows: UInt16, noReflow: Bool,
        provenance: CanonicalExternalTerminalProvenance
    ) async throws -> BackendSurfacePlacement { try reject() }

    func splitPane(
        requestID: UUID, surfaceID: SurfaceID, _ paneID: CmuxTerminalBackend.PaneID,
        direction: BackendSplitDirection, initialRatio: Float,
        launch: BackendTerminalLaunch, columns: UInt16?, rows: UInt16?
    ) async throws -> BackendSurfacePlacement { try reject() }

    func splitTab(
        requestID: UUID, _ surfaceID: SurfaceID,
        around paneID: CmuxTerminalBackend.PaneID,
        direction: BackendSplitDirection, initialRatio: Float
    ) async throws -> BackendSurfacePlacement { try reject() }

    func closePane(
        requestID: UUID, _ paneID: CmuxTerminalBackend.PaneID
    ) async throws -> BackendTopologyMutationReceipt { try reject() }

    func closeSurface(
        requestID: UUID, _ surfaceID: SurfaceID
    ) async throws -> BackendTopologyMutationReceipt { try reject() }

    func closeWorkspace(
        requestID: UUID, _ workspaceID: WorkspaceID
    ) async throws -> BackendTopologyMutationReceipt { try reject() }

    func renameWorkspace(
        requestID: UUID, _ workspaceID: WorkspaceID, name: String
    ) async throws -> BackendTopologyMutationReceipt { try reject() }

    func renameSurface(
        requestID: UUID, _ surfaceID: SurfaceID, name: String
    ) async throws -> BackendTopologyMutationReceipt { try reject() }

    func moveTab(
        requestID: UUID, _ surfaceID: SurfaceID,
        to paneID: CmuxTerminalBackend.PaneID, index: Int
    ) async throws -> BackendTopologyMutationReceipt { try reject() }

    func reorderTabs(
        requestID: UUID, in paneID: CmuxTerminalBackend.PaneID,
        surfaceIDs: [SurfaceID]
    ) async throws -> BackendTopologyMutationReceipt { try reject() }

    func reorderWorkspaces(
        requestID: UUID, _ workspaceIDs: [WorkspaceID]
    ) async throws -> BackendTopologyMutationReceipt { try reject() }

    func moveTabToNewWorkspace(
        requestID: UUID, _ surfaceID: SurfaceID, workspaceID: WorkspaceID,
        name: String?, index: Int?
    ) async throws -> BackendSurfacePlacement { try reject() }

    func setSplitRatio(
        requestID: UUID, around paneID: CmuxTerminalBackend.PaneID,
        direction: BackendSplitDirection, ratio: Float
    ) async throws -> BackendTopologyMutationReceipt { try reject() }
}

private actor SuspendedTopologyPlanBuilder {
    private let blockedWorkspaceID: UUID
    private var isBlocked = false
    private var hasResumed = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    init(blockedWorkspaceID: UUID) {
        self.blockedWorkspaceID = blockedWorkspaceID
    }

    func build(
        _ topology: CanonicalTopology
    ) async throws -> TerminalBackendTopologyProjectionPlan {
        if !hasResumed,
           topology.workspaces.contains(where: { $0.uuid.rawValue == blockedWorkspaceID }) {
            isBlocked = true
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                resumeContinuation = continuation
            }
        }
        return try TerminalBackendTopologyProjectionPlan(topology: topology)
    }

    func waitUntilBlocked() async {
        if isBlocked { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func resume() {
        hasResumed = true
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor ProjectionPlanCancellationGate {
    private var isSuspended = false
    private var suspendedWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        let waiters = suspendedWaiters
        suspendedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        if isSuspended { return }
        await withCheckedContinuation { continuation in
            suspendedWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor SuspendAfterFirstTopologyPlanBuilder {
    private var invocationCount = 0
    private var isBlocked = false
    private var hasResumed = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuations: [CheckedContinuation<Void, Never>] = []

    func build(
        _ topology: CanonicalTopology
    ) async throws -> TerminalBackendTopologyProjectionPlan {
        invocationCount += 1
        if invocationCount > 1, !hasResumed {
            isBlocked = true
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                resumeContinuations.append(continuation)
            }
        }
        return try TerminalBackendTopologyProjectionPlan(topology: topology)
    }

    func waitUntilBlocked() async {
        if isBlocked { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func resume() {
        hasResumed = true
        let continuations = resumeContinuations
        resumeContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor SuspendSecondTopologyPlanBuilder {
    private var invocationCount = 0
    private var retryIsBlocked = false
    private var retryBlockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var supersedingPlanWaiters: [CheckedContinuation<Void, Never>] = []
    private var retryContinuation: CheckedContinuation<Void, Never>?

    func build(
        _ topology: CanonicalTopology
    ) async throws -> TerminalBackendTopologyProjectionPlan {
        invocationCount += 1
        if invocationCount >= 3 {
            let waiters = supersedingPlanWaiters
            supersedingPlanWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        if invocationCount == 2 {
            retryIsBlocked = true
            let waiters = retryBlockedWaiters
            retryBlockedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                retryContinuation = continuation
            }
        }
        return try TerminalBackendTopologyProjectionPlan(topology: topology)
    }

    func waitUntilRetryIsBlocked() async {
        if retryIsBlocked { return }
        await withCheckedContinuation { continuation in
            retryBlockedWaiters.append(continuation)
        }
    }

    func waitUntilSupersedingPlanStarts() async {
        if invocationCount >= 3 { return }
        await withCheckedContinuation { continuation in
            supersedingPlanWaiters.append(continuation)
        }
    }

    func resumeRetry() {
        retryContinuation?.resume()
        retryContinuation = nil
    }
}
