import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct MobileTerminalScrollHandlerTests {
    @Test func replacementConnectionOwnsSharedClientStateUntilItCloses() {
        let service = MobileHostService.shared
        let controller = TerminalController.shared
        let connectionA = UUID()
        let connectionB = UUID()
        let surfaceID = UUID()
        defer {
            service.debugResetMobileLifecycleStateForTesting()
            controller.debugResetMobileViewportReportsForTesting()
            controller.mobileInteractionEpochsBySurfaceID[surfaceID] = nil
        }

        service.debugResetMobileLifecycleStateForTesting()
        controller.debugResetMobileViewportReportsForTesting()
        controller.debugSetMobileViewportReportForTesting(
            surfaceID: surfaceID,
            clientID: "shared-client",
            columns: 72,
            rows: 28
        )
        controller.mobileInteractionEpochsBySurfaceID[surfaceID] = [
            "shared-client": ["shared-session": 9]
        ]
        service.debugRecordClientIDForTesting("shared-client", connectionID: connectionA)
        service.debugRecordClientIDForTesting("shared-client", connectionID: connectionB)
        service.debugRecordInteractionIdentityForTesting(
            clientID: "shared-client",
            sessionID: "shared-session",
            connectionID: connectionA
        )
        service.debugRecordInteractionIdentityForTesting(
            clientID: "shared-client",
            sessionID: "shared-session",
            connectionID: connectionB
        )

        service.debugRemoveConnectionForTesting(id: connectionA)

        #expect(controller.debugMobileViewportReportClientIDsForTesting(surfaceID: surfaceID) == ["shared-client"])
        #expect(controller.mobileInteractionEpochsBySurfaceID[surfaceID] == [
            "shared-client": ["shared-session": 9]
        ])

        service.debugRemoveConnectionForTesting(id: connectionB)

        #expect(controller.debugMobileViewportReportClientIDsForTesting(surfaceID: surfaceID) == nil)
        #expect(controller.mobileInteractionEpochsBySurfaceID[surfaceID] == nil)
    }

    @Test func cleanupRetiresOnlyRequestedSurfaceMobileOrderingState() {
        let controller = TerminalController.shared
        let removedSurfaceID = UUID()
        let retainedSurfaceID = UUID()
        defer { controller.cleanupSurfaceState(surfaceIds: [removedSurfaceID, retainedSurfaceID]) }

        #expect(controller.advanceMobileRenderRevision(surfaceID: removedSurfaceID) == 1)
        #expect(controller.advanceMobileRenderRevision(surfaceID: retainedSurfaceID) == 1)
        #expect(controller.advanceMobileRenderRevision(surfaceID: retainedSurfaceID) == 2)
        controller.mobileInteractionEpochsBySurfaceID[removedSurfaceID] = [
            "client-a": ["session-a": 4]
        ]
        controller.mobileInteractionEpochsBySurfaceID[retainedSurfaceID] = [
            "client-b": ["session-b": 7]
        ]

        controller.cleanupSurfaceState(surfaceIds: [removedSurfaceID])

        #expect(controller.mobileRenderRevisionsBySurfaceID[removedSurfaceID] == nil)
        #expect(controller.mobileRenderRevisionsBySurfaceID[retainedSurfaceID] == 2)
        #expect(controller.mobileInteractionEpochsBySurfaceID[removedSurfaceID] == nil)
        #expect(controller.mobileInteractionEpochsBySurfaceID[retainedSurfaceID] == [
            "client-b": ["session-b": 7]
        ])
    }

    @Test func orderedRunPayloadAccepts32AndRejects33BeforeExecution() {
        func params(count: Int) -> [String: Any] {
            [
                "delta_runs": (0..<count).map { index in
                    [
                        "lines": index.isMultiple(of: 2) ? 1.0 : -1.0,
                        "col": index,
                        "row": index,
                    ] as [String: Any]
                }
            ]
        }

        #expect(TerminalController.shared.mobileScrollDirectionalRuns(params: params(count: 32))?.count == 32)
        #expect(TerminalController.shared.mobileScrollDirectionalRuns(params: params(count: 33)) == nil)
    }

    @Test func releasedSurfaceRejectsScrollAndZeroLineSettlement() throws {
        let harness = try makeTerminalHarness()
        defer { harness.restore() }
        harness.panel.surface.releaseSurfaceForTesting()

        let scroll = TerminalController.shared.v2MobileTerminalScroll(params: harness.params(
            epoch: 1,
            revision: 1,
            deltaLines: -8
        ))
        let settlement = TerminalController.shared.v2MobileTerminalScroll(params: harness.params(
            epoch: 1,
            revision: 1,
            deltaLines: 0,
            prefetchBeforeRows: 120,
            prefetchAfterRows: 600
        ))

        #expect(accepted(scroll) == false)
        #expect(accepted(settlement) == false)
    }

    @Test func clickEpochRejectsAnOlderScroll() throws {
        let harness = try makeTerminalHarness()
        defer { harness.restore() }

        let click = TerminalController.shared.v2MobileTerminalMouse(
            params: harness.params(epoch: 2, col: 7, row: 9),
            applyClick: { _, col, row in
                col == 7 && row == 9
            }
        )
        let staleScroll = TerminalController.shared.v2MobileTerminalScroll(params: harness.params(
            epoch: 1,
            revision: 1,
            deltaLines: -4
        ))

        guard case .ok = click else {
            return #expect(Bool(false), "live-surface click should be accepted")
        }
        #expect(accepted(staleScroll) == false)
    }

    @Test func restartedClientSessionAcceptsEpochOneWhileRejectingStaleOldSessionWork() throws {
        let harness = try makeTerminalHarness()
        defer { harness.restore() }
        var appliedSessions: [String] = []

        let oldSession = TerminalController.shared.v2MobileTerminalMouse(
            params: harness.params(epoch: 9, interactionSessionID: "old-session"),
            applyClick: { _, _, _ in
                appliedSessions.append("old")
                return true
            }
        )
        let restartedSession = TerminalController.shared.v2MobileTerminalMouse(
            params: harness.params(epoch: 1, interactionSessionID: "new-session"),
            applyClick: { _, _, _ in
                appliedSessions.append("new")
                return true
            }
        )
        let staleOldSession = TerminalController.shared.v2MobileTerminalMouse(
            params: harness.params(epoch: 8, interactionSessionID: "old-session"),
            applyClick: { _, _, _ in
                appliedSessions.append("stale")
                return true
            }
        )

        #expect(accepted(oldSession) == true)
        #expect(accepted(restartedSession) == true)
        #expect(accepted(staleOldSession) == false)
        #expect(appliedSessions == ["old", "new"])
    }

    @Test func replayFencingDoesNotRequireViewportGeometry() throws {
        let harness = try makeTerminalHarness()
        defer { harness.restore() }

        let replay = TerminalController.shared.v2MobileTerminalReplay(
            params: harness.params(epoch: 4)
        )
        let staleScroll = TerminalController.shared.v2MobileTerminalScroll(params: harness.params(
            epoch: 3,
            revision: 1,
            deltaLines: -4
        ))

        guard case .ok = replay else {
            Issue.record("interaction-fenced replay without viewport geometry should be accepted")
            return
        }
        #expect(accepted(staleScroll) == false, "cold replay must still advance the interaction fence")

        var columnsOnly = harness.params(epoch: 5)
        columnsOnly["viewport_columns"] = 80
        var rowsOnly = harness.params(epoch: 5)
        rowsOnly["viewport_rows"] = 24
        var generationOnly = harness.params(epoch: 5)
        generationOnly["viewport_generation"] = 1
        var missingClient = harness.params(epoch: 5)
        missingClient["client_id"] = nil
        missingClient["viewport_columns"] = 80
        missingClient["viewport_rows"] = 24

        for incomplete in [columnsOnly, rowsOnly, generationOnly, missingClient] {
            guard case .err(let code, _, _) = TerminalController.shared.v2MobileTerminalReplay(
                params: incomplete
            ) else {
                Issue.record("incomplete viewport geometry should be rejected")
                continue
            }
            #expect(code == "invalid_params")
        }
    }

    @Test func staleClickIsRejectedBeforeSurfaceMutation() throws {
        let harness = try makeTerminalHarness()
        defer { harness.restore() }

        let newerClick = TerminalController.shared.v2MobileTerminalMouse(
            params: harness.params(epoch: 2, col: 7, row: 9),
            applyClick: { _, _, _ in true }
        )
        var staleClickCalls = 0
        let staleClick = TerminalController.shared.v2MobileTerminalMouse(
            params: harness.params(epoch: 1, col: 11, row: 13),
            applyClick: { _, _, _ in
                staleClickCalls += 1
                return true
            }
        )

        #expect(accepted(newerClick) == true)
        #expect(accepted(staleClick) == false)
        #expect(interactionEpoch(staleClick) == 1)
        #expect(staleClickCalls == 0, "stale click must not reach the live-surface mutation")
    }

    @MainActor
    private struct TerminalHarness {
        let previousTabManager: TabManager?
        let manager: TabManager
        let workspace: Workspace
        let panel: TerminalPanel
        let clientID: String

        func params(
            epoch: Int,
            revision: Int? = nil,
            deltaLines: Double? = nil,
            col: Int = 0,
            row: Int = 0,
            interactionSessionID: String? = nil,
            prefetchBeforeRows: Int? = nil,
            prefetchAfterRows: Int? = nil
        ) -> [String: Any] {
            var params: [String: Any] = [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panel.id.uuidString,
                "client_id": clientID,
                "interaction_epoch": epoch,
                "col": col,
                "row": row,
            ]
            if let interactionSessionID {
                params["interaction_session_id"] = interactionSessionID
            }
            if let revision { params["client_scroll_revision"] = revision }
            if let deltaLines { params["delta_lines"] = deltaLines }
            if let prefetchBeforeRows { params["prefetch_before_rows"] = prefetchBeforeRows }
            if let prefetchAfterRows { params["prefetch_after_rows"] = prefetchAfterRows }
            return params
        }

        func restore() {
            TerminalController.shared.mobileInteractionEpochsBySurfaceID[panel.id] = nil
            TerminalController.shared.tabManager = previousTabManager
            panel.surface.releaseSurfaceForTesting()
        }
    }

    private func makeTerminalHarness() throws -> TerminalHarness {
        let controller = TerminalController.shared
        let previousTabManager = controller.tabManager
        let manager = TabManager()
        let workspace = manager.addWorkspace(
            select: true,
            eagerLoadTerminal: true,
            autoWelcomeIfNeeded: false,
            autoRefreshMetadata: false
        )
        let panel = try #require(workspace.focusedTerminalPanel)
        controller.tabManager = manager
        return TerminalHarness(
            previousTabManager: previousTabManager,
            manager: manager,
            workspace: workspace,
            panel: panel,
            clientID: "scroll-handler-\(UUID().uuidString)"
        )
    }

    private func accepted(_ result: TerminalController.V2CallResult) -> Bool? {
        payload(result)?["accepted"] as? Bool
    }

    private func interactionEpoch(_ result: TerminalController.V2CallResult) -> Int? {
        payload(result)?["interaction_epoch"] as? Int
    }

    private func payload(_ result: TerminalController.V2CallResult) -> [String: Any]? {
        guard case .ok(let rawPayload) = result else { return nil }
        return rawPayload as? [String: Any]
    }
}
