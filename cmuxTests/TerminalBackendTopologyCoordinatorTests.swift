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
    func durableProjectionHydratesBeforeFirstCanonicalWindowAssignment() async throws {
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
        registry.startupRestoreDidFinish()
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

    @MainActor
    private func makeProjectionComposition(
        failureReporter: @escaping @MainActor (String) -> Void = { _ in },
        browserEndpointFactory: (any TerminalBackendBrowserEndpointCreating)? = nil
    ) -> TerminalClientComposition {
        TerminalClientComposition(
            terminalPanelFactory: EmbeddedTerminalPanelFactory(
                dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies
            ),
            terminalBackendTopologyMutationCoordinator: TerminalBackendTopologyMutationCoordinator(
                failureReporter: failureReporter
            ),
            browserEndpointFactory: browserEndpointFactory
                ?? UnsupportedTerminalBackendBrowserEndpointFactory()
        )
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
                firstSurfaceNumber: firstSurfaceNumber
            )]
        )
    }

    private func makeScreen(
        surfaceIDs: [UUID],
        screenNumber: UInt64 = 1,
        paneNumber: UInt64 = 1,
        firstSurfaceNumber: UInt64 = 1
    ) -> CanonicalScreen {
        let paneUUID = CmuxTerminalBackend.PaneID(rawValue: UUID())
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
    private let failPreparation: Bool
    private let failCommitRevisions: Set<UInt64>

    init(
        legacyPlacements: Set<TerminalBackendTopologyPlacement> = [],
        allPresentationPlacements: Set<TerminalBackendTopologyPlacement>? = nil,
        failPreparation: Bool = false,
        failCommitRevisions: Set<UInt64> = []
    ) {
        self.legacyPlacements = legacyPlacements
        self.presentedPlacements = allPresentationPlacements ?? legacyPlacements
        self.failPreparation = failPreparation
        self.failCommitRevisions = failCommitRevisions
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

    func prepareCanonicalTopology(
        _ snapshot: TopologySnapshot,
        plan: TerminalBackendTopologyProjectionPlan
    ) throws -> TerminalBackendTopologyPreparedProjection {
        if failPreparation {
            throw ProjectionTestError()
        }
        return TerminalBackendTopologyPreparedProjection(
            commit: { [weak self] in
                if self?.failCommitRevisions.contains(snapshot.revision) == true {
                    throw ProjectionTestError()
                }
                self?.installedPlans.append(plan)
                self?.installedSnapshots.append(snapshot)
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
