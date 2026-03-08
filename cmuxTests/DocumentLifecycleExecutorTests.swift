import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class DocumentLifecycleExecutorTests: XCTestCase {
    func testVisibleMarkdownWithoutVisibleCurrentStatePlansShowInTree() {
        let current = makeCurrentMarkdownRecord(
            state: .boundHidden,
            residency: .destroyed,
            activeWindowMembership: false
        )
        let desired = makeDesiredMarkdownRecord(
            panelId: current.panelId,
            workspaceId: current.workspaceId,
            targetState: .awaitingAnchor,
            targetResidency: .visibleInActiveWindow,
            targetVisible: true,
            targetActive: false
        )

        let plan = DocumentLifecycleExecutor.makePlan(
            currentRecords: [current],
            desiredRecords: [desired]
        )

        XCTAssertEqual(plan.counts.panelCount, 1)
        XCTAssertEqual(plan.counts.showInTreeCount, 1)
        XCTAssertEqual(plan.records.first?.action, .showInTree)
    }

    func testHiddenMarkdownPlansDestroy() {
        let current = makeCurrentMarkdownRecord(
            state: .boundVisible,
            residency: .visibleInActiveWindow,
            activeWindowMembership: true
        )
        let desired = makeDesiredMarkdownRecord(
            panelId: current.panelId,
            workspaceId: current.workspaceId,
            targetState: .parked,
            targetResidency: .destroyed,
            targetVisible: false,
            targetActive: false
        )

        let plan = DocumentLifecycleExecutor.makePlan(
            currentRecords: [current],
            desiredRecords: [desired]
        )

        XCTAssertEqual(plan.counts.destroyCount, 1)
        XCTAssertEqual(plan.records.first?.action, .destroy)
    }

    func testDestroyedMarkdownHiddenStatePlansNoop() {
        let current = makeCurrentMarkdownRecord(
            state: .parked,
            residency: .destroyed,
            activeWindowMembership: false
        )
        let desired = makeDesiredMarkdownRecord(
            panelId: current.panelId,
            workspaceId: current.workspaceId,
            targetState: .parked,
            targetResidency: .destroyed,
            targetVisible: false,
            targetActive: false
        )

        let plan = DocumentLifecycleExecutor.makePlan(
            currentRecords: [current],
            desiredRecords: [desired]
        )

        XCTAssertEqual(plan.counts.noopCount, 1)
        XCTAssertEqual(plan.records.first?.action, .noop)
    }

    private func makeCurrentMarkdownRecord(
        panelId: UUID = UUID(),
        workspaceId: UUID = UUID(),
        state: PanelLifecycleState,
        residency: PanelResidency,
        activeWindowMembership: Bool
    ) -> PanelLifecycleRecordSnapshot {
        PanelLifecycleRecordSnapshot(
            panelId: panelId,
            workspaceId: workspaceId,
            paneId: UUID(),
            tabId: UUID(),
            panelType: .markdown,
            generation: 3,
            state: state,
            residency: residency,
            mountedWorkspace: true,
            selectedWorkspace: activeWindowMembership,
            retiringWorkspace: false,
            selectedInPane: activeWindowMembership,
            desiredVisible: activeWindowMembership,
            desiredActive: false,
            activeWindowMembership: activeWindowMembership,
            responderEligible: false,
            accessibilityParticipation: activeWindowMembership,
            backendProfile: PanelLifecycleShadowMapper.backendProfile(for: .markdown),
            anchor: nil
        )
    }

    private func makeDesiredMarkdownRecord(
        panelId: UUID = UUID(),
        workspaceId: UUID = UUID(),
        targetState: PanelLifecycleState,
        targetResidency: PanelResidency,
        targetVisible: Bool,
        targetActive: Bool
    ) -> PanelLifecycleDesiredRecordSnapshot {
        PanelLifecycleDesiredRecordSnapshot(
            panelId: panelId,
            workspaceId: workspaceId,
            panelType: .markdown,
            generation: 3,
            targetState: targetState,
            targetResidency: targetResidency,
            targetVisible: targetVisible,
            targetActive: targetActive,
            targetWindowNumber: targetVisible ? 41 : nil,
            targetAnchorId: nil,
            targetResponderEligible: false,
            targetAccessibilityParticipation: targetVisible,
            requiresCurrentGenerationAnchor: false,
            anchorReadyForVisibility: targetVisible
        )
    }
}
