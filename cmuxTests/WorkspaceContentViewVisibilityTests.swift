import XCTest

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

    func testPanelLifecycleStatePrefersHandoffForRetiringVisiblePanel() {
        XCTAssertEqual(
            PanelLifecycleShadowMapper.state(
                mountedWorkspace: true,
                retiringWorkspace: true,
                desiredVisible: true,
                anchorAttachedToWindow: false
            ),
            .handoff
        )
    }

    func testPanelLifecycleStateUsesAwaitingAnchorForSelectedVisiblePanelWithoutAnchor() {
        XCTAssertEqual(
            PanelLifecycleShadowMapper.state(
                mountedWorkspace: true,
                retiringWorkspace: false,
                desiredVisible: true,
                anchorAttachedToWindow: false
            ),
            .awaitingAnchor
        )
    }

    func testPanelLifecycleDesiredVisibleMatchesFocusedGapRule() {
        XCTAssertTrue(
            PanelLifecycleShadowMapper.desiredVisible(
                isWorkspaceVisible: true,
                selectedInPane: false,
                isFocused: true
            )
        )
    }

    func testPanelLifecycleResidencyDestroysHiddenRegenerablePanels() {
        XCTAssertEqual(
            PanelLifecycleShadowMapper.residency(
                residencyPolicy: .regenerable,
                activeWindowMembership: false,
                attachedToWindow: false,
                hasSuperview: false,
                desiredVisible: false
            ),
            .destroyed
        )
    }

    func testPanelLifecycleBackendProfileClassifiesMarkdownAsRegenerable() {
        let profile = PanelLifecycleShadowMapper.backendProfile(for: .markdown)
        XCTAssertEqual(profile.residencyPolicy, .regenerable)
        XCTAssertEqual(profile.interactionModel, .readOnly)
        XCTAssertEqual(profile.focusPolicy, .none)
    }

    func testPanelLifecycleRecordDoesNotCountHiddenPanelAsActiveWindowResident() {
        let workspaceId = UUID()
        let panelId = UUID()
        let record = PanelLifecycleShadowMapper.record(
            input: PanelLifecycleShadowRecordInput(
                panelId: panelId,
                workspaceId: workspaceId,
                paneId: UUID(),
                tabId: UUID(),
                panelType: .browser,
                mountedWorkspace: true,
                selectedWorkspace: true,
                retiringWorkspace: false,
                selectedInPane: false,
                isFocused: false,
                anchorFact: PanelLifecycleAnchorFact(
                    panelId: panelId,
                    workspaceId: workspaceId,
                    panelType: .browser,
                    anchorId: UUID(),
                    windowNumber: 42,
                    hasSuperview: true,
                    attachedToWindow: true,
                    hidden: false,
                    geometryRevision: 1,
                    desiredVisible: false,
                    desiredActive: false,
                    source: "visibility"
                ),
                anchorGeneration: 1
            ),
            activeWindowNumber: 42,
            handoffGeneration: 5
        )

        XCTAssertFalse(record.desiredVisible)
        XCTAssertFalse(record.activeWindowMembership)
        XCTAssertFalse(record.responderEligible)
        XCTAssertFalse(record.accessibilityParticipation)
    }
}
