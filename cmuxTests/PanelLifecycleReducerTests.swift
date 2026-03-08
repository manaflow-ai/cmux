import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class PanelLifecycleReducerTests: XCTestCase {
    func testMountedWorkspaceStateReplacesPreviousSnapshot() {
        let firstWorkspaceId = UUID()
        let secondWorkspaceId = UUID()
        var state = PanelLifecycleShadowState()

        state.reduce(
            .mountedWorkspaceState(
                mountedWorkspaceIds: [firstWorkspaceId],
                retiringWorkspaceId: nil,
                handoffGeneration: 1
            )
        )
        state.reduce(
            .mountedWorkspaceState(
                mountedWorkspaceIds: [secondWorkspaceId],
                retiringWorkspaceId: firstWorkspaceId,
                handoffGeneration: 2
            )
        )

        XCTAssertEqual(state.mountedWorkspaceIds, Set([secondWorkspaceId]))
        XCTAssertEqual(state.retiringWorkspaceId, firstWorkspaceId)
        XCTAssertEqual(state.handoffGeneration, 2)
    }

    func testAnchorFactLatestWriteWinsForSamePanel() {
        let panelId = UUID()
        let anchorId = UUID()
        var state = PanelLifecycleShadowState()

        state.reduce(.anchorFact(makeAnchorFact(panelId: panelId, anchorId: anchorId, windowNumber: 11, geometryRevision: 1)))
        state.reduce(.anchorFact(makeAnchorFact(panelId: panelId, anchorId: anchorId, windowNumber: 22, geometryRevision: 2)))

        XCTAssertEqual(state.anchorFact(panelId: panelId)?.windowNumber, 22)
        XCTAssertEqual(state.anchorFact(panelId: panelId)?.geometryRevision, 2)
        XCTAssertEqual(state.anchorGeneration(panelId: panelId), 1)
    }

    func testAnchorGenerationOnlyAdvancesWhenAnchorIdentityChanges() {
        let panelId = UUID()
        let firstAnchorId = UUID()
        let secondAnchorId = UUID()
        var state = PanelLifecycleShadowState()

        state.reduce(.anchorFact(makeAnchorFact(panelId: panelId, anchorId: firstAnchorId, windowNumber: 11, geometryRevision: 1)))
        state.reduce(.anchorFact(makeAnchorFact(panelId: panelId, anchorId: firstAnchorId, windowNumber: 11, geometryRevision: 2)))
        state.reduce(.anchorFact(makeAnchorFact(panelId: panelId, anchorId: secondAnchorId, windowNumber: 22, geometryRevision: 1)))

        XCTAssertEqual(state.anchorGeneration(panelId: panelId), 2)
        XCTAssertEqual(state.anchorFact(panelId: panelId)?.anchorId, secondAnchorId)
    }

    func testAnchorRemovalOnlyClearsTargetPanel() {
        let firstPanelId = UUID()
        let secondPanelId = UUID()
        var state = PanelLifecycleShadowState()

        state.reduce(.anchorFact(makeAnchorFact(panelId: firstPanelId, anchorId: UUID(), windowNumber: 1, geometryRevision: 1)))
        state.reduce(.anchorFact(makeAnchorFact(panelId: secondPanelId, anchorId: UUID(), windowNumber: 2, geometryRevision: 1)))
        state.reduce(.anchorRemoved(panelId: firstPanelId))

        XCTAssertNil(state.anchorFact(panelId: firstPanelId))
        XCTAssertEqual(state.anchorFact(panelId: secondPanelId)?.windowNumber, 2)
    }

    func testReducerDebugNamesMatchSpecShape() {
        XCTAssertEqual(
            PanelLifecycleShadowEvent.mountedWorkspaceState(
                mountedWorkspaceIds: [],
                retiringWorkspaceId: nil,
                handoffGeneration: 0
            ).debugName,
            "mountedWorkspaceState"
        )
        XCTAssertEqual(
            PanelLifecycleShadowEvent.anchorFact(
                makeAnchorFact(panelId: UUID(), anchorId: UUID(), windowNumber: 1, geometryRevision: 1)
            ).debugName,
            "anchorFact"
        )
        XCTAssertEqual(PanelLifecycleShadowEvent.anchorRemoved(panelId: UUID()).debugName, "anchorRemoved")
        XCTAssertEqual(PanelLifecycleState.awaitingAnchor.debugName, "awaitingAnchor")
        XCTAssertEqual(PanelResidency.parkedOffscreen.debugName, "parkedOffscreen")
    }

    private func makeAnchorFact(
        panelId: UUID,
        anchorId: UUID,
        windowNumber: Int?,
        geometryRevision: UInt64
    ) -> PanelLifecycleAnchorFact {
        PanelLifecycleAnchorFact(
            panelId: panelId,
            workspaceId: UUID(),
            panelType: .terminal,
            anchorId: anchorId,
            windowNumber: windowNumber,
            hasSuperview: true,
            attachedToWindow: true,
            hidden: false,
            geometryRevision: geometryRevision,
            desiredVisible: true,
            desiredActive: true,
            source: "unit"
        )
    }
}
