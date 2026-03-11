import XCTest
import CoreGraphics
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceContentViewVisibilityTests: XCTestCase {
    func testPanelVisibleInUIReturnsFalseWhenWorkspaceHidden() {
        XCTAssertFalse(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: false,
                isSelectedInPane: true,
                isFocused: true
            )
        )
    }

    func testPanelVisibleInUIReturnsTrueForSelectedPanel() {
        XCTAssertTrue(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: true,
                isFocused: false
            )
        )
    }

    func testPanelVisibleInUIReturnsTrueForFocusedPanelDuringTransientSelectionGap() {
        XCTAssertTrue(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: false,
                isFocused: true
            )
        )
    }

    func testPanelVisibleInUIReturnsFalseWhenNeitherSelectedNorFocused() {
        XCTAssertFalse(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: false,
                isFocused: false
            )
        )
    }

    func testPortalHostLeasingStateRejectsSmallerSameContextReplacementByDefault() {
        var leasing = PortalHostLeasingState()
        let contextId = UUID()
        let firstHost = NSObject()
        let secondHost = NSObject()

        let firstClaim = leasing.claim(
            hostId: ObjectIdentifier(firstHost),
            contextId: contextId,
            inWindow: true,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        XCTAssertTrue(firstClaim.accepted)

        let secondClaim = leasing.claim(
            hostId: ObjectIdentifier(secondHost),
            contextId: contextId,
            inWindow: true,
            bounds: CGRect(x: 0, y: 0, width: 80, height: 80)
        )

        XCTAssertFalse(secondClaim.accepted)
        XCTAssertEqual(secondClaim.activeLease?.hostId, ObjectIdentifier(firstHost))
        XCTAssertFalse(secondClaim.blockedByLock)
    }

    func testPortalHostLeasingStateForcesDistinctReplacementWhenArmed() {
        var leasing = PortalHostLeasingState()
        let contextId = UUID()
        let firstHost = NSObject()
        let secondHost = NSObject()

        _ = leasing.claim(
            hostId: ObjectIdentifier(firstHost),
            contextId: contextId,
            inWindow: true,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        leasing.prepareForNextDistinctReplacement(contextId: contextId)

        let forcedClaim = leasing.claim(
            hostId: ObjectIdentifier(secondHost),
            contextId: contextId,
            inWindow: true,
            bounds: CGRect(x: 0, y: 0, width: 20, height: 20)
        )

        XCTAssertTrue(forcedClaim.accepted)
        XCTAssertTrue(forcedClaim.forcedDistinctReplacement)
        XCTAssertEqual(forcedClaim.activeLease?.hostId, ObjectIdentifier(secondHost))
        XCTAssertEqual(forcedClaim.replacedLease?.hostId, ObjectIdentifier(firstHost))
    }

    func testPortalHostLeasingStateLocksForcedReplacementAgainstImmediateThrash() {
        var leasing = PortalHostLeasingState()
        let contextId = UUID()
        let firstHost = NSObject()
        let secondHost = NSObject()
        let thirdHost = NSObject()

        _ = leasing.claim(
            hostId: ObjectIdentifier(firstHost),
            contextId: contextId,
            inWindow: true,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        leasing.prepareForNextDistinctReplacement(contextId: contextId)
        _ = leasing.claim(
            hostId: ObjectIdentifier(secondHost),
            contextId: contextId,
            inWindow: true,
            bounds: CGRect(x: 0, y: 0, width: 20, height: 20)
        )

        let blockedClaim = leasing.claim(
            hostId: ObjectIdentifier(thirdHost),
            contextId: contextId,
            inWindow: true,
            bounds: CGRect(x: 0, y: 0, width: 400, height: 400)
        )

        XCTAssertFalse(blockedClaim.accepted)
        XCTAssertTrue(blockedClaim.blockedByLock)
        XCTAssertEqual(blockedClaim.activeLease?.hostId, ObjectIdentifier(secondHost))
    }

    func testPortalHostLeasingStateAllowsReplacementAcrossContexts() {
        var leasing = PortalHostLeasingState()
        let firstHost = NSObject()
        let secondHost = NSObject()

        _ = leasing.claim(
            hostId: ObjectIdentifier(firstHost),
            contextId: UUID(),
            inWindow: true,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200)
        )

        let secondClaim = leasing.claim(
            hostId: ObjectIdentifier(secondHost),
            contextId: UUID(),
            inWindow: true,
            bounds: CGRect(x: 0, y: 0, width: 40, height: 40)
        )

        XCTAssertTrue(secondClaim.accepted)
        XCTAssertTrue(secondClaim.didAcquireOwnership)
        XCTAssertEqual(secondClaim.activeLease?.hostId, ObjectIdentifier(secondHost))
    }

    func testPortalHostLeasingStateDoesNotForceReplacementForNilContext() {
        var leasing = PortalHostLeasingState()
        let firstHost = NSObject()
        let secondHost = NSObject()

        let firstClaim = leasing.claim(
            hostId: ObjectIdentifier(firstHost),
            contextId: nil,
            inWindow: true,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        XCTAssertTrue(firstClaim.accepted)

        let secondClaim = leasing.claim(
            hostId: ObjectIdentifier(secondHost),
            contextId: nil,
            inWindow: true,
            bounds: CGRect(x: 0, y: 0, width: 80, height: 80)
        )

        XCTAssertFalse(secondClaim.accepted)
        XCTAssertFalse(secondClaim.forcedDistinctReplacement)
        XCTAssertFalse(secondClaim.blockedByLock)
        XCTAssertEqual(secondClaim.activeLease?.hostId, ObjectIdentifier(firstHost))
    }

    func testPortalHostLeasingStatePreservesUsableLeaseWhenSameHostTemporarilyLeavesWindow() {
        var leasing = PortalHostLeasingState()
        let host = NSObject()
        let contextId = UUID()

        let initialClaim = leasing.claim(
            hostId: ObjectIdentifier(host),
            contextId: contextId,
            inWindow: true,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        XCTAssertTrue(initialClaim.accepted)
        XCTAssertEqual(initialClaim.activeLease?.hostId, ObjectIdentifier(host))
        XCTAssertTrue(initialClaim.activeLease?.inWindow == true)
        XCTAssertEqual(initialClaim.activeLease?.area, 40000)

        let transientClaim = leasing.claim(
            hostId: ObjectIdentifier(host),
            contextId: contextId,
            inWindow: false,
            bounds: .zero
        )

        XCTAssertTrue(transientClaim.accepted)
        XCTAssertEqual(transientClaim.activeLease?.hostId, ObjectIdentifier(host))
        XCTAssertTrue(transientClaim.activeLease?.inWindow == true)
        XCTAssertEqual(transientClaim.activeLease?.area, 40000)
    }

    func testPortalHostLeasingStateDoesNotLetOldHostReclaimAfterForcedReplacementTransientlyLeavesWindow() {
        var leasing = PortalHostLeasingState()
        let contextId = UUID()
        let oldHost = NSObject()
        let newHost = NSObject()

        _ = leasing.claim(
            hostId: ObjectIdentifier(oldHost),
            contextId: contextId,
            inWindow: true,
            bounds: CGRect(x: 0, y: 0, width: 137, height: 134)
        )
        leasing.prepareForNextDistinctReplacement(contextId: contextId)

        let replacementClaim = leasing.claim(
            hostId: ObjectIdentifier(newHost),
            contextId: contextId,
            inWindow: true,
            bounds: CGRect(x: 0, y: 0, width: 274, height: 134)
        )
        XCTAssertTrue(replacementClaim.accepted)
        XCTAssertEqual(replacementClaim.activeLease?.hostId, ObjectIdentifier(newHost))

        let transientClaim = leasing.claim(
            hostId: ObjectIdentifier(newHost),
            contextId: contextId,
            inWindow: false,
            bounds: .zero
        )
        XCTAssertTrue(transientClaim.accepted)
        XCTAssertEqual(transientClaim.activeLease?.hostId, ObjectIdentifier(newHost))
        XCTAssertTrue(transientClaim.activeLease?.inWindow == true)

        let reclaimAttempt = leasing.claim(
            hostId: ObjectIdentifier(oldHost),
            contextId: contextId,
            inWindow: true,
            bounds: CGRect(x: 0, y: 0, width: 137, height: 134)
        )

        XCTAssertFalse(reclaimAttempt.accepted)
        XCTAssertTrue(reclaimAttempt.blockedByLock)
        XCTAssertEqual(reclaimAttempt.activeLease?.hostId, ObjectIdentifier(newHost))
    }

    func testWorkspaceGraphSnapshotMergeRetainsSelectionAndFocusAcrossTransientLiveGap() {
        let workspaceId = UUID()
        let paneId = UUID()
        let primaryPanelId = UUID()
        let secondaryPanelId = UUID()

        let previous = makeWorkspaceGraphSnapshot(
            workspaceId: workspaceId,
            panes: [
                WorkspacePaneGraphState(
                    paneId: paneId,
                    panelIds: [primaryPanelId, secondaryPanelId],
                    selectedPanelId: secondaryPanelId
                )
            ],
            focusedPaneId: paneId,
            focusedPanelId: secondaryPanelId
        )

        let live = makeWorkspaceGraphSnapshot(
            workspaceId: workspaceId,
            panes: [
                WorkspacePaneGraphState(
                    paneId: paneId,
                    panelIds: [primaryPanelId, secondaryPanelId],
                    selectedPanelId: nil
                )
            ],
            focusedPaneId: nil,
            focusedPanelId: nil
        )

        let merged = previous.merged(with: live)

        XCTAssertEqual(merged.selectedPanelId(inPane: PaneID(id: paneId)), secondaryPanelId)
        XCTAssertEqual(merged.focusedPaneId, paneId)
        XCTAssertEqual(merged.focusedPanelId, secondaryPanelId)
    }

    func testWorkspaceGraphSnapshotMergeRetainsZoomedPaneAcrossTransientLiveGap() {
        let workspaceId = UUID()
        let zoomedPaneId = UUID()
        let panelId = UUID()

        let previous = makeWorkspaceGraphSnapshot(
            workspaceId: workspaceId,
            panes: [
                WorkspacePaneGraphState(
                    paneId: zoomedPaneId,
                    panelIds: [panelId],
                    selectedPanelId: panelId
                )
            ],
            focusedPaneId: zoomedPaneId,
            focusedPanelId: panelId,
            zoomedPaneId: zoomedPaneId
        )

        let live = makeWorkspaceGraphSnapshot(
            workspaceId: workspaceId,
            panes: [
                WorkspacePaneGraphState(
                    paneId: zoomedPaneId,
                    panelIds: [panelId],
                    selectedPanelId: panelId
                )
            ],
            focusedPaneId: nil,
            focusedPanelId: nil,
            zoomedPaneId: nil
        )

        let merged = previous.merged(with: live)

        XCTAssertEqual(merged.zoomedPaneId, zoomedPaneId)
        XCTAssertEqual(merged.splitZoomRenderIdentity, "zoom:\(zoomedPaneId.uuidString)")
    }

    func testWorkspaceGraphSnapshotMergeDoesNotRetainZoomedPaneAfterExplicitUnzoom() {
        let workspaceId = UUID()
        let zoomedPaneId = UUID()
        let panelId = UUID()

        let previous = makeWorkspaceGraphSnapshot(
            workspaceId: workspaceId,
            panes: [
                WorkspacePaneGraphState(
                    paneId: zoomedPaneId,
                    panelIds: [panelId],
                    selectedPanelId: panelId
                )
            ],
            focusedPaneId: zoomedPaneId,
            focusedPanelId: panelId,
            zoomedPaneId: zoomedPaneId
        )

        let live = makeWorkspaceGraphSnapshot(
            workspaceId: workspaceId,
            panes: [
                WorkspacePaneGraphState(
                    paneId: zoomedPaneId,
                    panelIds: [panelId],
                    selectedPanelId: panelId
                )
            ],
            focusedPaneId: zoomedPaneId,
            focusedPanelId: panelId,
            zoomedPaneId: nil
        )

        let merged = previous.merged(with: live)

        XCTAssertNil(merged.zoomedPaneId)
        XCTAssertEqual(merged.splitZoomRenderIdentity, "unzoomed")
    }

    func testWindowGraphStateKeepsSelectedAndRetiringWorkspacesMountedDuringHandoff() {
        let firstWorkspaceId = UUID()
        let secondWorkspaceId = UUID()

        var graphState = WindowGraphState()
        _ = graphState.apply(
            .bootstrap(
                makeWorkspaceEngineInputs(
                    orderedWorkspaceIds: [firstWorkspaceId, secondWorkspaceId],
                    selectedWorkspaceId: firstWorkspaceId
                )
            )
        )

        let transition = graphState.apply(
            .selectWorkspace(
                secondWorkspaceId,
                makeWorkspaceEngineInputs(
                    orderedWorkspaceIds: [firstWorkspaceId, secondWorkspaceId],
                    selectedWorkspaceId: secondWorkspaceId
                )
            )
        )

        XCTAssertEqual(transition, .handoffStarted)
        XCTAssertEqual(graphState.selectedWorkspaceId, secondWorkspaceId)
        XCTAssertEqual(graphState.retiringWorkspaceId, firstWorkspaceId)
        XCTAssertEqual(graphState.mountedWorkspaceIds, [secondWorkspaceId, firstWorkspaceId])

        _ = graphState.apply(
            .completeWorkspaceHandoff(
                makeWorkspaceEngineInputs(
                    orderedWorkspaceIds: [firstWorkspaceId, secondWorkspaceId],
                    selectedWorkspaceId: secondWorkspaceId
                )
            )
        )

        XCTAssertEqual(graphState.retiringWorkspaceId, nil)
        XCTAssertEqual(graphState.mountedWorkspaceIds, [secondWorkspaceId])
    }

    func testWindowGraphStateReconcileDropsClosedRetiringWorkspace() {
        let firstWorkspaceId = UUID()
        let secondWorkspaceId = UUID()

        var graphState = WindowGraphState()
        _ = graphState.apply(
            .bootstrap(
                makeWorkspaceEngineInputs(
                    orderedWorkspaceIds: [firstWorkspaceId, secondWorkspaceId],
                    selectedWorkspaceId: firstWorkspaceId
                )
            )
        )
        _ = graphState.apply(
            .selectWorkspace(
                secondWorkspaceId,
                makeWorkspaceEngineInputs(
                    orderedWorkspaceIds: [firstWorkspaceId, secondWorkspaceId],
                    selectedWorkspaceId: secondWorkspaceId
                )
            )
        )

        _ = graphState.apply(
            .reconcile(
                makeWorkspaceEngineInputs(
                    orderedWorkspaceIds: [secondWorkspaceId],
                    selectedWorkspaceId: secondWorkspaceId
                )
            )
        )

        XCTAssertEqual(graphState.selectedWorkspaceId, secondWorkspaceId)
        XCTAssertNil(graphState.retiringWorkspaceId)
        XCTAssertEqual(graphState.mountedWorkspaceIds, [secondWorkspaceId])
    }

    func testWindowGraphStateReconcileRetainsMergedWorkspaceSnapshotState() {
        let workspaceId = UUID()
        let paneId = UUID()
        let firstPanelId = UUID()
        let secondPanelId = UUID()
        let previousSnapshot = makeWorkspaceGraphSnapshot(
            workspaceId: workspaceId,
            panes: [
                WorkspacePaneGraphState(
                    paneId: paneId,
                    panelIds: [firstPanelId, secondPanelId],
                    selectedPanelId: secondPanelId
                )
            ],
            focusedPaneId: paneId,
            focusedPanelId: secondPanelId
        )
        let transientSnapshot = makeWorkspaceGraphSnapshot(
            workspaceId: workspaceId,
            panes: [
                WorkspacePaneGraphState(
                    paneId: paneId,
                    panelIds: [firstPanelId, secondPanelId],
                    selectedPanelId: nil
                )
            ],
            focusedPaneId: nil,
            focusedPanelId: nil
        )

        var graphState = WindowGraphState()
        _ = graphState.apply(
            .bootstrap(
                makeWorkspaceEngineInputs(
                    orderedWorkspaceIds: [workspaceId],
                    selectedWorkspaceId: workspaceId,
                    workspaceSnapshotsById: [workspaceId: previousSnapshot]
                )
            )
        )

        _ = graphState.apply(
            .reconcile(
                makeWorkspaceEngineInputs(
                    orderedWorkspaceIds: [workspaceId],
                    selectedWorkspaceId: workspaceId,
                    workspaceSnapshotsById: [workspaceId: transientSnapshot]
                )
            )
        )

        guard let mergedSnapshot = graphState.workspaceSnapshotsById[workspaceId] else {
            XCTFail("Expected merged workspace snapshot for \(workspaceId)")
            return
        }
        XCTAssertEqual(mergedSnapshot.selectedPanelId(inPane: PaneID(id: paneId)), secondPanelId)
        XCTAssertEqual(mergedSnapshot.focusedPaneId, paneId)
        XCTAssertEqual(mergedSnapshot.focusedPanelId, secondPanelId)
    }

    private func makeWorkspaceEngineInputs(
        orderedWorkspaceIds: [UUID],
        selectedWorkspaceId: UUID?,
        retainedWorkspaceIds: Set<UUID> = [],
        isWorkspaceCycleHot: Bool = false,
        workspaceSnapshotsById: [UUID: WorkspaceGraphSnapshot] = [:]
    ) -> WorkspaceEngineRenderInputs {
        let resolvedSnapshotsById = workspaceSnapshotsById.isEmpty
            ? Dictionary(uniqueKeysWithValues: orderedWorkspaceIds.map { workspaceId in
                (workspaceId, makeWorkspaceGraphSnapshot(workspaceId: workspaceId))
            })
            : workspaceSnapshotsById

        return WorkspaceEngineRenderInputs(
            orderedWorkspaceIds: orderedWorkspaceIds,
            selectedWorkspaceId: selectedWorkspaceId,
            retainedWorkspaceIds: retainedWorkspaceIds,
            isWorkspaceCycleHot: isWorkspaceCycleHot,
            workspaceSnapshotsById: resolvedSnapshotsById
        )
    }

    private func makeWorkspaceGraphSnapshot(
        workspaceId: UUID,
        panes: [WorkspacePaneGraphState] = [],
        focusedPaneId: UUID? = nil,
        focusedPanelId: UUID? = nil,
        zoomedPaneId: UUID? = nil
    ) -> WorkspaceGraphSnapshot {
        let paneNodes = panes.map { pane in
            ExternalTreeNode.pane(
                ExternalPaneNode(
                    id: pane.paneId.uuidString,
                    frame: PixelRect(x: 0, y: 0, width: 200, height: 120),
                    tabs: pane.panelIds.map { ExternalTab(id: $0.uuidString, title: "Panel") },
                    selectedTabId: pane.selectedPanelId?.uuidString
                )
            )
        }
        let paneTree: ExternalTreeNode = paneNodes.first ?? .pane(
            ExternalPaneNode(
                id: UUID().uuidString,
                frame: PixelRect(x: 0, y: 0, width: 200, height: 120),
                tabs: [],
                selectedTabId: nil
            )
        )
        let layoutSnapshot = LayoutSnapshot(
            containerFrame: PixelRect(x: 0, y: 0, width: 200, height: 120),
            panes: panes.map { pane in
                PaneGeometry(
                    paneId: pane.paneId.uuidString,
                    frame: PixelRect(x: 0, y: 0, width: 200, height: 120),
                    selectedTabId: pane.selectedPanelId?.uuidString,
                    tabIds: pane.panelIds.map(\.uuidString)
                )
            },
            focusedPaneId: focusedPaneId?.uuidString,
            timestamp: 0
        )

        return WorkspaceGraphSnapshot(
            workspaceId: workspaceId,
            paneTree: paneTree,
            layoutSnapshot: layoutSnapshot,
            panes: panes,
            focusedPaneId: focusedPaneId,
            focusedPanelId: focusedPanelId,
            zoomedPaneId: zoomedPaneId
        )
    }
}
