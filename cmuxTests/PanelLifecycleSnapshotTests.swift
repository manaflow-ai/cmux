import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class PanelLifecycleSnapshotTests: XCTestCase {
    func testRecordMarksFocusedVisibleTerminalAsResponderEligible() {
        let workspaceId = UUID()
        let panelId = UUID()
        let anchor = makeAnchorFact(panelId: panelId, workspaceId: workspaceId, panelType: .terminal, windowNumber: 41, hidden: false)

        let record = PanelLifecycleShadowMapper.record(
            input: PanelLifecycleShadowRecordInput(
                panelId: panelId,
                workspaceId: workspaceId,
                paneId: UUID(),
                tabId: UUID(),
                panelType: .terminal,
                mountedWorkspace: true,
                selectedWorkspace: true,
                retiringWorkspace: false,
                selectedInPane: true,
                isFocused: true,
                anchorFact: anchor,
                anchorGeneration: 4
            ),
            activeWindowNumber: 41,
            handoffGeneration: 9
        )

        XCTAssertEqual(record.state, .boundVisible)
        XCTAssertEqual(record.residency, .visibleInActiveWindow)
        XCTAssertTrue(record.desiredVisible)
        XCTAssertTrue(record.desiredActive)
        XCTAssertTrue(record.activeWindowMembership)
        XCTAssertTrue(record.responderEligible)
        XCTAssertTrue(record.accessibilityParticipation)
        XCTAssertEqual(record.generation, 9)
        XCTAssertEqual(record.anchor?.anchorId, anchor.anchorId)
        XCTAssertEqual(record.anchor?.anchorGeneration, 4)
    }

    func testRecordKeepsHiddenMarkdownOutOfActiveWindowAndDestroysItWhenDetached() {
        let record = PanelLifecycleShadowMapper.record(
            input: PanelLifecycleShadowRecordInput(
                panelId: UUID(),
                workspaceId: UUID(),
                paneId: UUID(),
                tabId: UUID(),
                panelType: .markdown,
                mountedWorkspace: false,
                selectedWorkspace: false,
                retiringWorkspace: false,
                selectedInPane: false,
                isFocused: false,
                anchorFact: nil,
                anchorGeneration: 0
            ),
            activeWindowNumber: 9,
            handoffGeneration: 4
        )

        XCTAssertEqual(record.state, .parked)
        XCTAssertEqual(record.residency, .destroyed)
        XCTAssertFalse(record.desiredVisible)
        XCTAssertFalse(record.desiredActive)
        XCTAssertFalse(record.activeWindowMembership)
        XCTAssertFalse(record.responderEligible)
        XCTAssertFalse(record.accessibilityParticipation)
        XCTAssertEqual(record.generation, 0)
    }

    func testRetiringVisiblePanelUsesHandoffGenerationAndState() {
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
                selectedWorkspace: false,
                retiringWorkspace: true,
                selectedInPane: true,
                isFocused: true,
                anchorFact: nil,
                anchorGeneration: 0
            ),
            activeWindowNumber: nil,
            handoffGeneration: 33
        )

        XCTAssertEqual(record.state, .handoff)
        XCTAssertEqual(record.generation, 33)
        XCTAssertTrue(record.desiredVisible)
    }

    func testCountsAggregateMountedAndVisibleRecords() {
        let visibleRecord = PanelLifecycleShadowMapper.record(
            input: PanelLifecycleShadowRecordInput(
                panelId: UUID(),
                workspaceId: UUID(),
                paneId: UUID(),
                tabId: UUID(),
                panelType: .terminal,
                mountedWorkspace: true,
                selectedWorkspace: true,
                retiringWorkspace: false,
                selectedInPane: true,
                isFocused: true,
                anchorFact: makeAnchorFact(panelId: UUID(), workspaceId: UUID(), panelType: .terminal, windowNumber: 5, hidden: false),
                anchorGeneration: 2
            ),
            activeWindowNumber: 5,
            handoffGeneration: 7
        )
        let hiddenRecord = PanelLifecycleShadowMapper.record(
            input: PanelLifecycleShadowRecordInput(
                panelId: UUID(),
                workspaceId: UUID(),
                paneId: UUID(),
                tabId: UUID(),
                panelType: .markdown,
                mountedWorkspace: true,
                selectedWorkspace: false,
                retiringWorkspace: false,
                selectedInPane: false,
                isFocused: false,
                anchorFact: nil,
                anchorGeneration: 0
            ),
            activeWindowNumber: 5,
            handoffGeneration: 7
        )

        let counts = PanelLifecycleShadowMapper.counts(for: [visibleRecord, hiddenRecord], mountedWorkspaceCount: 1)

        XCTAssertEqual(counts.panelCount, 2)
        XCTAssertEqual(counts.anchoredPanelCount, 1)
        XCTAssertEqual(counts.nonVisibleAnchoredPanelCount, 0)
        XCTAssertEqual(counts.inactiveTabAnchoredPanelCount, 0)
        XCTAssertEqual(counts.visibleInActiveWindowCount, 1)
        XCTAssertEqual(counts.responderEligibleCount, 1)
        XCTAssertEqual(counts.accessibilityParticipationCount, 1)
        XCTAssertEqual(counts.mountedWorkspaceCount, 1)
    }

    func testCountsExposeInactiveAnchoredTabsSeparatelyFromVisiblePanels() {
        let workspaceId = UUID()

        let visibleRecord = PanelLifecycleShadowMapper.record(
            input: PanelLifecycleShadowRecordInput(
                panelId: UUID(),
                workspaceId: workspaceId,
                paneId: UUID(),
                tabId: UUID(),
                panelType: .terminal,
                mountedWorkspace: true,
                selectedWorkspace: true,
                retiringWorkspace: false,
                selectedInPane: true,
                isFocused: true,
                anchorFact: makeAnchorFact(panelId: UUID(), workspaceId: workspaceId, panelType: .terminal, windowNumber: 7, hidden: false),
                anchorGeneration: 1
            ),
            activeWindowNumber: 7,
            handoffGeneration: 2
        )
        let inactiveAnchoredRecord = PanelLifecycleShadowMapper.record(
            input: PanelLifecycleShadowRecordInput(
                panelId: UUID(),
                workspaceId: workspaceId,
                paneId: UUID(),
                tabId: UUID(),
                panelType: .browser,
                mountedWorkspace: true,
                selectedWorkspace: true,
                retiringWorkspace: false,
                selectedInPane: false,
                isFocused: false,
                anchorFact: makeAnchorFact(panelId: UUID(), workspaceId: workspaceId, panelType: .browser, windowNumber: 7, hidden: false),
                anchorGeneration: 3
            ),
            activeWindowNumber: 7,
            handoffGeneration: 2
        )

        let counts = PanelLifecycleShadowMapper.counts(
            for: [visibleRecord, inactiveAnchoredRecord],
            mountedWorkspaceCount: 1
        )

        XCTAssertEqual(counts.panelCount, 2)
        XCTAssertEqual(counts.anchoredPanelCount, 2)
        XCTAssertEqual(counts.nonVisibleAnchoredPanelCount, 1)
        XCTAssertEqual(counts.inactiveTabAnchoredPanelCount, 1)
        XCTAssertEqual(counts.visibleInActiveWindowCount, 1)
    }

    func testDesiredRecordWaitsForAnchorBeforeVisibleCommit() {
        let record = PanelLifecycleShadowMapper.record(
            input: PanelLifecycleShadowRecordInput(
                panelId: UUID(),
                workspaceId: UUID(),
                paneId: UUID(),
                tabId: UUID(),
                panelType: .terminal,
                mountedWorkspace: true,
                selectedWorkspace: true,
                retiringWorkspace: false,
                selectedInPane: true,
                isFocused: true,
                anchorFact: nil,
                anchorGeneration: 0
            ),
            activeWindowNumber: 7,
            handoffGeneration: 2
        )

        let desired = PanelLifecycleShadowMapper.desiredRecord(from: record, activeWindowNumber: 7)

        XCTAssertEqual(desired.targetState, .awaitingAnchor)
        XCTAssertEqual(desired.targetResidency, .visibleInActiveWindow)
        XCTAssertTrue(desired.targetVisible)
        XCTAssertTrue(desired.targetActive)
        XCTAssertNil(desired.targetAnchorId)
        XCTAssertTrue(desired.requiresCurrentGenerationAnchor)
        XCTAssertFalse(desired.anchorReadyForVisibility)
    }

    func testDesiredRecordCarriesVisibleAnchorIdentity() {
        let panelId = UUID()
        let workspaceId = UUID()
        let anchor = makeAnchorFact(
            panelId: panelId,
            workspaceId: workspaceId,
            panelType: .terminal,
            windowNumber: 7,
            hidden: false
        )
        let record = PanelLifecycleShadowMapper.record(
            input: PanelLifecycleShadowRecordInput(
                panelId: panelId,
                workspaceId: workspaceId,
                paneId: UUID(),
                tabId: UUID(),
                panelType: .terminal,
                mountedWorkspace: true,
                selectedWorkspace: true,
                retiringWorkspace: false,
                selectedInPane: true,
                isFocused: true,
                anchorFact: anchor,
                anchorGeneration: 1
            ),
            activeWindowNumber: 7,
            handoffGeneration: 2
        )

        let desired = PanelLifecycleShadowMapper.desiredRecord(from: record, activeWindowNumber: 7)

        XCTAssertEqual(desired.targetAnchorId, anchor.anchorId)
        XCTAssertTrue(desired.anchorReadyForVisibility)
    }

    func testDesiredRecordParksHiddenBrowserOffscreen() {
        let record = PanelLifecycleShadowMapper.record(
            input: PanelLifecycleShadowRecordInput(
                panelId: UUID(),
                workspaceId: UUID(),
                paneId: UUID(),
                tabId: UUID(),
                panelType: .browser,
                mountedWorkspace: true,
                selectedWorkspace: false,
                retiringWorkspace: false,
                selectedInPane: false,
                isFocused: false,
                anchorFact: nil,
                anchorGeneration: 0
            ),
            activeWindowNumber: 9,
            handoffGeneration: 4
        )

        let desired = PanelLifecycleShadowMapper.desiredRecord(from: record, activeWindowNumber: 9)

        XCTAssertEqual(desired.targetState, .boundHidden)
        XCTAssertEqual(desired.targetResidency, .parkedOffscreen)
        XCTAssertFalse(desired.targetVisible)
        XCTAssertFalse(desired.targetActive)
        XCTAssertNil(desired.targetAnchorId)
        XCTAssertFalse(desired.requiresCurrentGenerationAnchor)
    }

    func testDesiredRecordDetachesHiddenTerminalRetained() {
        let record = PanelLifecycleShadowMapper.record(
            input: PanelLifecycleShadowRecordInput(
                panelId: UUID(),
                workspaceId: UUID(),
                paneId: UUID(),
                tabId: UUID(),
                panelType: .terminal,
                mountedWorkspace: true,
                selectedWorkspace: false,
                retiringWorkspace: false,
                selectedInPane: false,
                isFocused: false,
                anchorFact: nil,
                anchorGeneration: 0
            ),
            activeWindowNumber: 9,
            handoffGeneration: 4
        )

        let desired = PanelLifecycleShadowMapper.desiredRecord(from: record, activeWindowNumber: 9)

        XCTAssertEqual(desired.targetState, .boundHidden)
        XCTAssertEqual(desired.targetResidency, .detachedRetained)
        XCTAssertFalse(desired.targetVisible)
        XCTAssertFalse(desired.targetActive)
        XCTAssertNil(desired.targetAnchorId)
        XCTAssertFalse(desired.requiresCurrentGenerationAnchor)
    }

    func testDesiredCountsAndDivergenceExposeShadowGap() {
        let visibleRecord = PanelLifecycleShadowMapper.record(
            input: PanelLifecycleShadowRecordInput(
                panelId: UUID(),
                workspaceId: UUID(),
                paneId: UUID(),
                tabId: UUID(),
                panelType: .terminal,
                mountedWorkspace: true,
                selectedWorkspace: true,
                retiringWorkspace: false,
                selectedInPane: true,
                isFocused: true,
                anchorFact: nil,
                anchorGeneration: 0
            ),
            activeWindowNumber: 3,
            handoffGeneration: 5
        )
        let hiddenBrowserRecord = PanelLifecycleShadowMapper.record(
            input: PanelLifecycleShadowRecordInput(
                panelId: UUID(),
                workspaceId: UUID(),
                paneId: UUID(),
                tabId: UUID(),
                panelType: .browser,
                mountedWorkspace: true,
                selectedWorkspace: false,
                retiringWorkspace: false,
                selectedInPane: false,
                isFocused: false,
                anchorFact: nil,
                anchorGeneration: 0
            ),
            activeWindowNumber: 3,
            handoffGeneration: 5
        )

        let desiredRecords = [
            PanelLifecycleShadowMapper.desiredRecord(from: visibleRecord, activeWindowNumber: 3),
            PanelLifecycleShadowMapper.desiredRecord(from: hiddenBrowserRecord, activeWindowNumber: 3),
        ]
        let desiredCounts = PanelLifecycleShadowMapper.desiredCounts(for: desiredRecords)
        let divergence = PanelLifecycleShadowMapper.divergenceCounts(
            currentRecords: [visibleRecord, hiddenBrowserRecord],
            desiredRecords: desiredRecords
        )
        let terminalPlan = TerminalLifecycleExecutor.makePlan(
            currentRecords: [visibleRecord, hiddenBrowserRecord],
            desiredRecords: desiredRecords
        )

        XCTAssertEqual(desiredCounts.panelCount, 2)
        XCTAssertEqual(desiredCounts.visibleTargetCount, 1)
        XCTAssertEqual(desiredCounts.activeTargetCount, 1)
        XCTAssertEqual(desiredCounts.awaitingAnchorCount, 1)
        XCTAssertEqual(desiredCounts.visibleInActiveWindowCount, 1)
        XCTAssertEqual(desiredCounts.parkedOffscreenCount, 1)
        XCTAssertEqual(desiredCounts.detachedRetainedCount, 0)
        XCTAssertEqual(desiredCounts.destroyedCount, 0)

        XCTAssertEqual(divergence.panelCount, 2)
        XCTAssertEqual(divergence.stateMismatchCount, 1)
        XCTAssertEqual(divergence.residencyMismatchCount, 2)
        XCTAssertEqual(divergence.activeWindowMismatchCount, 1)
        XCTAssertEqual(divergence.responderMismatchCount, 1)
        XCTAssertEqual(divergence.accessibilityMismatchCount, 1)
        XCTAssertEqual(divergence.anchorRequiredButMissingCount, 1)

        XCTAssertEqual(terminalPlan.counts.panelCount, 1)
        XCTAssertEqual(terminalPlan.counts.waitForAnchorCount, 1)
        XCTAssertEqual(terminalPlan.records.first?.action, .waitForAnchor)
    }

    private func makeAnchorFact(
        panelId: UUID,
        workspaceId: UUID,
        panelType: PanelType,
        windowNumber: Int?,
        hidden: Bool
    ) -> PanelLifecycleAnchorFact {
        PanelLifecycleAnchorFact(
            panelId: panelId,
            workspaceId: workspaceId,
            panelType: panelType,
            anchorId: UUID(),
            windowNumber: windowNumber,
            hasSuperview: true,
            attachedToWindow: true,
            hidden: hidden,
            geometryRevision: 1,
            desiredVisible: !hidden,
            desiredActive: !hidden,
            source: "snapshot"
        )
    }
}
