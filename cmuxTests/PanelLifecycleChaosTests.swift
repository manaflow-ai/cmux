import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class PanelLifecycleChaosTests: XCTestCase {
    func testOutOfOrderMountedAndAnchorEventsConvergeToSameState() {
        let workspaceId = UUID()
        let panelId = UUID()
        let anchor = makeAnchorFact(
            panelId: panelId,
            workspaceId: workspaceId,
            anchorId: UUID(),
            windowNumber: 7,
            geometryRevision: 3
        )

        var ordered = PanelLifecycleShadowState()
        ordered.reduce(
            .mountedWorkspaceState(
                mountedWorkspaceIds: [workspaceId],
                retiringWorkspaceId: nil,
                handoffGeneration: 10
            )
        )
        ordered.reduce(.anchorFact(anchor))

        var outOfOrder = PanelLifecycleShadowState()
        outOfOrder.reduce(.anchorFact(anchor))
        outOfOrder.reduce(
            .mountedWorkspaceState(
                mountedWorkspaceIds: [workspaceId],
                retiringWorkspaceId: nil,
                handoffGeneration: 10
            )
        )

        XCTAssertEqual(outOfOrder, ordered)
    }

    func testSupersededMountedWorkspaceStateDropsOldRetiringWorkspace() {
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
                retiringWorkspaceId: nil,
                handoffGeneration: 2
            )
        )

        XCTAssertEqual(state.mountedWorkspaceIds, Set([secondWorkspaceId]))
        XCTAssertNil(state.retiringWorkspaceId)
        XCTAssertEqual(state.handoffGeneration, 2)
    }

    func testInterleavedPanelEventsStayPanelScoped() {
        let firstPanelId = UUID()
        let secondPanelId = UUID()
        let workspaceId = UUID()
        var state = PanelLifecycleShadowState()

        state.reduce(.anchorFact(makeAnchorFact(panelId: firstPanelId, workspaceId: workspaceId, anchorId: UUID(), windowNumber: 1, geometryRevision: 1)))
        state.reduce(.anchorFact(makeAnchorFact(panelId: secondPanelId, workspaceId: workspaceId, anchorId: UUID(), windowNumber: 2, geometryRevision: 1)))
        state.reduce(.anchorFact(makeAnchorFact(panelId: firstPanelId, workspaceId: workspaceId, anchorId: UUID(), windowNumber: 3, geometryRevision: 2)))
        state.reduce(.anchorRemoved(panelId: secondPanelId))

        XCTAssertEqual(state.anchorFact(panelId: firstPanelId)?.windowNumber, 3)
        XCTAssertEqual(state.anchorFact(panelId: firstPanelId)?.geometryRevision, 2)
        XCTAssertNil(state.anchorFact(panelId: secondPanelId))
    }

    func testAnchorReplacementAfterRemovalKeepsMonotonicGenerationPerPanel() {
        let workspaceId = UUID()
        let panelId = UUID()
        let firstAnchorId = UUID()
        let secondAnchorId = UUID()
        var state = PanelLifecycleShadowState()

        state.reduce(
            .anchorFact(
                makeAnchorFact(
                    panelId: panelId,
                    workspaceId: workspaceId,
                    anchorId: firstAnchorId,
                    windowNumber: 1,
                    geometryRevision: 1
                )
            )
        )
        state.reduce(.anchorRemoved(panelId: panelId))
        state.reduce(
            .anchorFact(
                makeAnchorFact(
                    panelId: panelId,
                    workspaceId: workspaceId,
                    anchorId: secondAnchorId,
                    windowNumber: 2,
                    geometryRevision: 1
                )
            )
        )

        XCTAssertEqual(state.anchorGeneration(panelId: panelId), 2)
        XCTAssertEqual(state.anchorFact(panelId: panelId)?.anchorId, secondAnchorId)
    }

    private func makeAnchorFact(
        panelId: UUID,
        workspaceId: UUID,
        anchorId: UUID,
        windowNumber: Int?,
        geometryRevision: UInt64
    ) -> PanelLifecycleAnchorFact {
        PanelLifecycleAnchorFact(
            panelId: panelId,
            workspaceId: workspaceId,
            panelType: .browser,
            anchorId: anchorId,
            windowNumber: windowNumber,
            hasSuperview: true,
            attachedToWindow: true,
            hidden: false,
            geometryRevision: geometryRevision,
            desiredVisible: true,
            desiredActive: false,
            source: "chaos"
        )
    }
}
