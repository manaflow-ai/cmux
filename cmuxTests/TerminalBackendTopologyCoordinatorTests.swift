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
    func multipleScreensFailClosedWithoutReplacingSwiftTopology() async throws {
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
        let screens = [
            makeScreen(surfaceIDs: [UUID()]),
            makeScreen(
                surfaceIDs: [UUID()],
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

        #expect(projector.installedSnapshots.isEmpty)
        #expect(failure?.contains("2") == true)
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

    @MainActor
    private func makeProjectionComposition(
        failureReporter: @escaping @MainActor (String) -> Void = { _ in }
    ) -> TerminalClientComposition {
        TerminalClientComposition(
            terminalPanelFactory: EmbeddedTerminalPanelFactory(
                dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies
            ),
            terminalBackendTopologyMutationCoordinator: TerminalBackendTopologyMutationCoordinator(
                failureReporter: failureReporter
            )
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
}

@MainActor
private final class RecordingTopologyProjector: TerminalBackendTopologyProjecting {
    var legacyPlacements: Set<TerminalBackendTopologyPlacement>
    private(set) var legacyReadCount = 0
    private(set) var installedSnapshots: [TopologySnapshot] = []

    init(legacyPlacements: Set<TerminalBackendTopologyPlacement> = []) {
        self.legacyPlacements = legacyPlacements
    }

    func legacyTerminalPlacements() -> Set<TerminalBackendTopologyPlacement> {
        legacyReadCount += 1
        return legacyPlacements
    }

    func installCanonicalTopology(_ snapshot: TopologySnapshot) throws {
        installedSnapshots.append(snapshot)
    }
}
