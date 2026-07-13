import CmuxSettings
import Foundation
import Testing
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct MobileHostServiceSettingsTests {
    @Test func advertisesOrderedTerminalScrollRuns() {
        #expect(MobileHostService.mobileHostCapabilities.contains("terminal.scroll.ordered_runs.v1"))
    }

    @Test func mobileHostListenerDefaultsOffUntilIOSPairingIsEnabled() throws {
        let suiteName = "MobileHostServiceSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!MobileHostService.isListeningEnabled(defaults: defaults))

        defaults.set(true, forKey: MobileHostService.listeningEnabledDefaultsKey)
        #expect(MobileHostService.isListeningEnabled(defaults: defaults))

        defaults.set(false, forKey: MobileHostService.listeningEnabledDefaultsKey)
        #expect(!MobileHostService.isListeningEnabled(defaults: defaults))
    }

    @Test func configuredPortDefaultsToCatalogDefaultWhenUnset() throws {
        let suiteName = "MobileHostServiceSettingsTests.Port.Default.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expected = SettingCatalog().mobile.iOSPairingPort.defaultValue
        #expect(MobileHostService.configuredPort(defaults: defaults) == expected)
    }

    @Test func configuredPortHonorsValidOverride() throws {
        let suiteName = "MobileHostServiceSettingsTests.Port.Valid.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(9000, forKey: MobileHostService.portDefaultsKey)
        #expect(MobileHostService.configuredPort(defaults: defaults) == 9000)
    }

    @Test(arguments: [0, -1, 70000, 65536])
    func configuredPortFallsBackForOutOfRangeOverride(invalidPort: Int) throws {
        let suiteName = "MobileHostServiceSettingsTests.Port.Invalid.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(invalidPort, forKey: MobileHostService.portDefaultsKey)
        let expected = SettingCatalog().mobile.iOSPairingPort.defaultValue
        #expect(MobileHostService.configuredPort(defaults: defaults) == expected)
    }

    @Test func resolvedDesiredPortIsNilForInvalidSoRunningListenerIsNotDisturbed() throws {
        let suiteName = "MobileHostServiceSettingsTests.Port.Resolved.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Unset → catalog default (a valid desired port).
        #expect(MobileHostService.resolvedDesiredPort(defaults: defaults)
            == SettingCatalog().mobile.iOSPairingPort.defaultValue)

        // Valid override → that port.
        defaults.set(58_470, forKey: MobileHostService.portDefaultsKey)
        #expect(MobileHostService.resolvedDesiredPort(defaults: defaults) == 58_470)

        // Invalid override → nil, so syncToSettings keeps the running listener
        // on its applied port instead of restarting onto the default.
        defaults.set(70_000, forKey: MobileHostService.portDefaultsKey)
        #expect(MobileHostService.resolvedDesiredPort(defaults: defaults) == nil)
    }

    @Test func portApplyPreBindClassifiesNonBindCases() {
        // Out of range → invalid, regardless of anything else.
        #expect(MobileHostService.portApplyPreBindOutcome(enabled: true, currentBoundPort: nil, requestedPort: 0) == .invalid)
        #expect(MobileHostService.portApplyPreBindOutcome(enabled: true, currentBoundPort: nil, requestedPort: 70000) == .invalid)
        // Pairing off → saved for when it's enabled.
        #expect(MobileHostService.portApplyPreBindOutcome(enabled: false, currentBoundPort: nil, requestedPort: 58465) == .savedWhileDisabled)
        // Already bound to the requested port → applied, no bind attempt.
        #expect(MobileHostService.portApplyPreBindOutcome(enabled: true, currentBoundPort: 58465, requestedPort: 58465) == .applied(58465))
    }

    @Test func portApplyPreBindReturnsNilWhenABindIsNeeded() {
        // Enabled, valid, different from the bound port → needs a real bind
        // attempt (make-before-break), signalled by nil.
        #expect(MobileHostService.portApplyPreBindOutcome(enabled: true, currentBoundPort: 58465, requestedPort: 58470) == nil)
        // Not running yet, enabled, valid → also needs a bind.
        #expect(MobileHostService.portApplyPreBindOutcome(enabled: true, currentBoundPort: nil, requestedPort: 58470) == nil)
    }

    @Test func syncDecisionStartsStopsAndNoOpsForEnabledState() {
        // Disabled: stop only when something is running, otherwise no-op.
        #expect(MobileHostService.syncDecision(enabled: false, listenerRunning: false, desiredPort: 58465, appliedPort: nil) == .noop)
        #expect(MobileHostService.syncDecision(enabled: false, listenerRunning: true, desiredPort: 58465, appliedPort: 58465) == .stop)
        // Enabled but not running: start.
        #expect(MobileHostService.syncDecision(enabled: true, listenerRunning: false, desiredPort: 58465, appliedPort: nil) == .start)
    }

    @Test func syncDecisionRestartsOnlyWhenPortChanges() {
        // Running on the desired port: nothing to do (does not drop connections
        // on unrelated UserDefaults writes).
        #expect(MobileHostService.syncDecision(enabled: true, listenerRunning: true, desiredPort: 58465, appliedPort: 58465) == .noop)
        // Running on a different port than desired: restart to rebind.
        #expect(MobileHostService.syncDecision(enabled: true, listenerRunning: true, desiredPort: 9000, appliedPort: 58465) == .restart)
        // Running but the applied port is unknown: restart to reconcile.
        #expect(MobileHostService.syncDecision(enabled: true, listenerRunning: true, desiredPort: 58465, appliedPort: nil) == .restart)
    }
}

@MainActor
final class MobileInteractionSessionEpochXCTests: XCTestCase {
    func testRestartedClientSessionAcceptsEpochOneWhileRejectingStaleOldSessionWork() {
        let controller = TerminalController.shared
        let surfaceID = UUID()
        defer { controller.mobileInteractionEpochsBySurfaceID[surfaceID] = nil }

        func params(epoch: Int, sessionID: String) -> [String: Any] {
            [
                "client_id": "persisted-client",
                "interaction_session_id": sessionID,
                "interaction_epoch": epoch,
            ]
        }

        XCTAssertTrue(controller.recordMobileInteractionEpoch(
            params: params(epoch: 9, sessionID: "old-session"),
            surfaceID: surfaceID,
            rejectOlder: true
        ))
        XCTAssertTrue(controller.recordMobileInteractionEpoch(
            params: params(epoch: 1, sessionID: "new-session"),
            surfaceID: surfaceID,
            rejectOlder: true
        ))
        XCTAssertFalse(controller.recordMobileInteractionEpoch(
            params: params(epoch: 8, sessionID: "old-session"),
            surfaceID: surfaceID,
            rejectOlder: true
        ))
    }

    func testOverlappingConnectionsRetireOnlyTheirOwnedSession() {
        let service = MobileHostService.shared
        let controller = TerminalController.shared
        let oldConnection = UUID()
        let newConnection = UUID()
        let surfaceID = UUID()
        defer {
            service.debugResetMobileLifecycleStateForTesting()
            controller.debugResetMobileViewportReportsForTesting()
        }

        service.debugResetMobileLifecycleStateForTesting()
        controller.debugResetMobileViewportReportsForTesting()
        controller.debugSetMobileViewportReportForTesting(
            surfaceID: surfaceID,
            clientID: "persisted-client",
            columns: 72,
            rows: 28
        )
        controller.mobileInteractionEpochsBySurfaceID[surfaceID] = [
            "persisted-client": ["old-session": 9, "new-session": 1]
        ]
        service.debugRecordInteractionIdentityForTesting(
            clientID: "persisted-client",
            sessionID: "old-session",
            connectionID: oldConnection
        )
        service.debugRecordInteractionIdentityForTesting(
            clientID: "persisted-client",
            sessionID: "new-session",
            connectionID: newConnection
        )

        service.debugRemoveConnectionForTesting(id: oldConnection)

        XCTAssertEqual(controller.mobileInteractionEpochsBySurfaceID[surfaceID], [
            "persisted-client": ["new-session": 1]
        ])
        XCTAssertEqual(
            controller.debugMobileViewportReportClientIDsForTesting(surfaceID: surfaceID),
            ["persisted-client"]
        )

        service.debugRemoveConnectionForTesting(id: newConnection)

        XCTAssertNil(controller.mobileInteractionEpochsBySurfaceID[surfaceID])
        XCTAssertNil(controller.debugMobileViewportReportClientIDsForTesting(surfaceID: surfaceID))
    }
}

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

#if DEBUG
@Suite(.serialized)
@MainActor
struct MobileHostMacScopedMutationAuthorizationTests {
    @Test func ignoresUnknownAttachTokenForBroadWorkspaceRequests() async {
        let service = MobileHostService.shared
        service.debugConfigureAcceptedStackAuthTokenForTesting("cmux-dev-token")
        defer { service.debugConfigureAcceptedStackAuthTokenForTesting(nil) }
        for method in ["workspace.list", "workspace.create"] {
            let request = MobileHostRPCRequest(
                id: method,
                method: method,
                params: [:],
                auth: MobileHostRPCAuth(attachToken: "stale-ticket", stackAccessToken: "cmux-dev-token")
            )
            let result = await service.debugAuthorizationError(for: request)
            #expect(result == nil)
        }
    }

    @Test func rejectsMacScopedMutationsWithoutAttachToken() async {
        let service = MobileHostService.shared
        service.debugConfigureAcceptedStackAuthTokenForTesting("cmux-dev-token")
        defer { service.debugConfigureAcceptedStackAuthTokenForTesting(nil) }
        let cases: [(String, [String: String])] = [
            ("workspace.create", ["group_id": "group-main"]),
            ("workspace.move", ["workspace_id": "workspace-main", "before_workspace_id": "workspace-next"]),
            ("workspace.group.action", ["group_id": "group-main", "action": "rename"]),
            ("workspace.group.create", ["title": "Ops"]),
        ]
        for (method, params) in cases {
            let request = MobileHostRPCRequest(
                id: method,
                method: method,
                params: params,
                auth: MobileHostRPCAuth(attachToken: nil, stackAccessToken: "cmux-dev-token")
            )
            let result = await service.debugAuthorizationError(for: request)
            guard case let .failure(error) = result else {
                return #expect(Bool(false), "missing attach token should reject \(method)")
            }
            #expect(error.code == "forbidden")
        }
    }

    @Test func rejectsMacScopedMutationsWithUnknownAttachToken() async {
        let service = MobileHostService.shared
        service.debugConfigureAcceptedStackAuthTokenForTesting("cmux-dev-token")
        defer { service.debugConfigureAcceptedStackAuthTokenForTesting(nil) }
        let cases: [(String, [String: String])] = [
            ("workspace.create", ["group_id": "group-main"]),
            ("workspace.move", ["workspace_id": "workspace-main", "before_workspace_id": "workspace-next"]),
            ("workspace.group.action", ["group_id": "group-main", "action": "rename"]),
            ("workspace.group.create", ["title": "Ops"]),
        ]
        for (method, params) in cases {
            let request = MobileHostRPCRequest(
                id: method,
                method: method,
                params: params,
                auth: MobileHostRPCAuth(attachToken: "stale-ticket", stackAccessToken: "cmux-dev-token")
            )
            let result = await service.debugAuthorizationError(for: request)
            guard case let .failure(error) = result else {
                return #expect(Bool(false), "stale attach token should reject \(method)")
            }
            #expect(error.code == "forbidden")
        }
    }
}
#endif
