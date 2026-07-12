import AppKit
import CmuxControlSocket
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression tests for https://github.com/manaflow-ai/cmux/issues/7939 /
/// https://github.com/manaflow-ai/cmux/issues/5781: a notification addressed
/// with a stale workspace id but a live surface id must be retargeted to the
/// surface's CURRENT workspace at delivery time — not dropped (async path) and
/// not recorded against the stale workspace (sync path). The unread ring and
/// the stored notification must land on the pane that owns the surface.
@MainActor
final class AgentNotificationLiveRetargetTests: XCTestCase {
    private struct Fixture {
        let store: TerminalNotificationStore
        let appDelegate: AppDelegate
        let manager: TabManager
        let claimedWorkspace: Workspace
        let owningWorkspace: Workspace
        let panelId: UUID
        let restore: () -> Void
    }

    private func makeFixture() throws -> Fixture {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let claimedWorkspace = manager.addWorkspace(select: false)
        let owningWorkspace = manager.addWorkspace(select: true)
        guard let panelId = owningWorkspace.focusedPanelId else {
            throw XCTSkip("Expected a focused panel in the owning workspace")
        }

        let restore = {
            for workspace in [claimedWorkspace, owningWorkspace] where manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }
        return Fixture(
            store: store,
            appDelegate: appDelegate,
            manager: manager,
            claimedWorkspace: claimedWorkspace,
            owningWorkspace: owningWorkspace,
            panelId: panelId,
            restore: restore
        )
    }

    func testQueuedNotificationRetargetsToSurfaceCurrentWorkspace() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        // Claimed workspace is stale (e.g. captured at spawn, pane since moved):
        // the surface lives in `owningWorkspace`.
        TerminalMutationBus.shared.enqueueNotification(
            tabId: fixture.claimedWorkspace.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "All done"
        )
        TerminalMutationBus.shared.drainForTesting()

        let recorded = fixture.store.notifications.filter { $0.title == "Claude Code" }
        XCTAssertEqual(
            recorded.map(\.tabId),
            [fixture.owningWorkspace.id],
            "Queued notification must be retargeted to the surface's current workspace, not dropped or misfiled"
        )
        XCTAssertEqual(recorded.first?.surfaceId, fixture.panelId)
        XCTAssertTrue(
            fixture.store.hasUnreadNotification(forTabId: fixture.owningWorkspace.id, surfaceId: fixture.panelId),
            "Unread ring must appear on the pane that owns the surface"
        )
        XCTAssertFalse(
            fixture.store.hasUnreadNotification(forTabId: fixture.claimedWorkspace.id, surfaceId: fixture.panelId),
            "Unread ring must not appear under the stale workspace"
        )
    }

    func testSyncDeliveredNotificationRetargetsToSurfaceCurrentWorkspace() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        TerminalController.shared.deliverNotificationSynchronously(
            tabId: fixture.claimedWorkspace.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "All done"
        )

        let recorded = fixture.store.notifications.filter { $0.title == "Claude Code" }
        XCTAssertEqual(
            recorded.map(\.tabId),
            [fixture.owningWorkspace.id],
            "Synchronously delivered notification must be recorded under the surface's current workspace"
        )
        XCTAssertEqual(recorded.first?.surfaceId, fixture.panelId)
        XCTAssertTrue(
            fixture.store.hasUnreadNotification(forTabId: fixture.owningWorkspace.id, surfaceId: fixture.panelId)
        )
    }

    func testSyncDeliverySupersedesPendingNotificationUnderStaleClaimedKey() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        // An older async notification still queued under the stale claimed
        // workspace key...
        TerminalMutationBus.shared.enqueueNotification(
            tabId: fixture.claimedWorkspace.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Working",
            body: "Old queued"
        )
        // ...must be superseded by a newer synchronous notification for the
        // same surface, even though sync delivery retargets to the owning
        // workspace — a different queue key than the stale claim.
        TerminalController.shared.deliverNotificationSynchronously(
            tabId: fixture.claimedWorkspace.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "New sync"
        )
        TerminalMutationBus.shared.drainForTesting()

        let recorded = fixture.store.notifications.filter { $0.title == "Claude Code" }
        XCTAssertEqual(
            recorded.map(\.body),
            ["New sync"],
            "A stale-keyed pending notification must not survive (or replace) the newer synchronous one for the same surface"
        )
        XCTAssertEqual(recorded.map(\.tabId), [fixture.owningWorkspace.id])
    }

    func testResolveDeliveryTargetToleratesOutOfRangePid() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        // A 64-bit pid beyond pid_t range (any socket caller controls this
        // value) must not trap; it degrades to the surface probe like any
        // unresolvable pid.
        let result = TerminalController.shared.v2AgentResolveDeliveryTarget(params: [
            "pid": Int(Int32.max) + 1,
            "surface_id": fixture.panelId.uuidString,
        ])
        guard case .ok(let payload) = result, let dict = payload as? [String: Any] else {
            return XCTFail("Expected surface-sourced resolution for an out-of-range pid, got \(result)")
        }
        XCTAssertEqual(dict["source"] as? String, "surface")
        XCTAssertEqual(dict["workspace_id"] as? String, fixture.owningWorkspace.id.uuidString)
    }

    func testSurfaceScopedClearDiscardsStaleKeyedPendingNotification() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        // Queued under the stale claimed workspace key...
        TerminalMutationBus.shared.enqueueNotification(
            tabId: fixture.claimedWorkspace.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Stale queued"
        )
        // ...then the pane (live workspace) is cleared BEFORE the queue
        // drains: the stale-keyed pending entry must not outlive the clear
        // and resurrect the notification the user just dismissed.
        fixture.store.clearNotifications(
            forTabId: fixture.owningWorkspace.id,
            surfaceId: fixture.panelId
        )
        TerminalMutationBus.shared.drainForTesting()

        XCTAssertTrue(
            fixture.store.notifications.filter { $0.title == "Claude Code" }.isEmpty,
            "A cleared pane must stay cleared; the stale-keyed pending entry must not deliver after the clear"
        )
        XCTAssertFalse(
            fixture.store.hasUnreadNotification(forTabId: fixture.owningWorkspace.id, surfaceId: fixture.panelId)
        )
    }

    func testCreateForCallerFollowsMovedPreferredSurface() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        // `cmux notify` from a moved pane: spawn-time CMUX_WORKSPACE_ID is
        // stale but CMUX_SURFACE_ID is the pane's stable identity — the
        // notification must follow the surface, not fall back to the stale
        // workspace's focused pane.
        let result = TerminalController.shared.v2NotificationCreateForCaller(params: [
            "preferred_workspace_id": fixture.claimedWorkspace.id.uuidString,
            "preferred_surface_id": fixture.panelId.uuidString,
            "title": "Caller notify",
            "body": "Body",
        ])
        guard case .ok(let payload) = result, let dict = payload as? [String: Any] else {
            return XCTFail("Expected delivery, got \(result)")
        }
        XCTAssertEqual(dict["workspace_id"] as? String, fixture.owningWorkspace.id.uuidString)
        XCTAssertEqual(dict["surface_id"] as? String, fixture.panelId.uuidString)
        let recorded = fixture.store.notifications.filter { $0.title == "Caller notify" }
        XCTAssertEqual(recorded.map(\.tabId), [fixture.owningWorkspace.id])
        XCTAssertEqual(recorded.first?.surfaceId, fixture.panelId)
    }

    func testCreateForTargetRejectsSurfaceOutsideClaimedWorkspace() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        // SECURITY boundary: `notification.create_for_target` is reachable
        // through the cloud relay, whose authorization only pins workspace_id
        // to the relay's owner workspace. The membership guard here is what
        // confines a relay caller to that workspace — it must NOT re-home a
        // surface owned by another workspace (a leaked pane UUID would allow
        // cross-workspace injection).
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: fixture.claimedWorkspace.id,
            surfaceID: nil,
            paneID: nil
        )
        let resolution = TerminalController.shared.controlNotificationCreateForTarget(
            routing: routing,
            workspaceID: fixture.claimedWorkspace.id,
            surfaceID: fixture.panelId,
            title: "Target notify",
            subtitle: "",
            body: "Body"
        )
        XCTAssertEqual(
            resolution,
            .surfaceNotFound(fixture.panelId),
            "create_for_target must stay confined to the claimed workspace (relay authorization boundary)"
        )
        XCTAssertTrue(fixture.store.notifications.filter { $0.title == "Target notify" }.isEmpty)
    }

    func testCreateForSurfaceFollowsMovedSurface() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        // `notification.create_for_surface` is local-only (not relay-
        // reachable), so a moved surface follows its live owner — including
        // when the claimed routing workspace no longer lists it.
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: fixture.claimedWorkspace.id,
            surfaceID: nil,
            paneID: nil
        )
        let resolution = TerminalController.shared.controlNotificationCreateForSurface(
            routing: routing,
            surfaceID: fixture.panelId,
            title: "Surface notify",
            subtitle: "",
            body: "Body"
        )
        guard case .delivered(let workspaceID, let surfaceID, _) = resolution else {
            return XCTFail("A moved surface must be re-homed, not rejected; got \(resolution)")
        }
        XCTAssertEqual(workspaceID, fixture.owningWorkspace.id)
        XCTAssertEqual(surfaceID, fixture.panelId)
        let recorded = fixture.store.notifications.filter { $0.title == "Surface notify" }
        XCTAssertEqual(recorded.map(\.tabId), [fixture.owningWorkspace.id])
    }

    func testRebindKeepsNewerDestinationKeyedPendingNotification() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        // Mid-move race: the destination already owns the surface and a hook
        // enqueues a valid notification under the destination key BEFORE
        // rebind runs. Rebind's source-scoped discard must not drop it.
        TerminalMutationBus.shared.enqueueNotification(
            tabId: fixture.owningWorkspace.id,
            surfaceId: fixture.panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "Destination queued"
        )
        fixture.store.rebindSurfaceNotifications(
            fromTabId: fixture.claimedWorkspace.id,
            toTabId: fixture.owningWorkspace.id,
            surfaceId: fixture.panelId
        )
        TerminalMutationBus.shared.drainForTesting()

        let recorded = fixture.store.notifications.filter { $0.title == "Claude Code" }
        XCTAssertEqual(
            recorded.map(\.body),
            ["Destination queued"],
            "Rebind must discard only source-keyed pending entries, not a newer destination-keyed one"
        )
        XCTAssertEqual(recorded.map(\.tabId), [fixture.owningWorkspace.id])
    }

    func testPidSignalCombiningRequiresTTYMatch() {
        let tty = AgentDeliveryTargetCandidate(workspaceId: UUID(), surfaceId: UUID())
        let otherEnv = AgentDeliveryTargetCandidate(workspaceId: UUID(), surfaceId: UUID())
        XCTAssertEqual(agentDeliveryTargetCombining(ttyTarget: tty, envTarget: nil), tty)
        XCTAssertEqual(
            agentDeliveryTargetCombining(
                ttyTarget: tty,
                envTarget: AgentDeliveryTargetCandidate(workspaceId: otherEnv.workspaceId, surfaceId: tty.surfaceId)
            ),
            tty,
            "A corroborating env surface keeps the tty answer"
        )
        XCTAssertNil(
            agentDeliveryTargetCombining(ttyTarget: tty, envTarget: otherEnv),
            "Disagreeing signals must refuse to resolve"
        )
        XCTAssertNil(
            agentDeliveryTargetCombining(ttyTarget: nil, envTarget: otherEnv),
            "Inherited CMUX_SURFACE_ID alone is spawn-time evidence (leakable from the operator's pane) and must never resolve by itself"
        )
        XCTAssertNil(agentDeliveryTargetCombining(ttyTarget: nil, envTarget: nil))
    }

    func testTTYDeviceMatchRequiresUniqueSurface() {
        let w1 = UUID(), s1 = UUID(), w2 = UUID(), s2 = UUID()
        let bindings: [(workspaceId: UUID, surfaceId: UUID, ttyDevice: Int64)] = [
            (workspaceId: w1, surfaceId: s1, ttyDevice: 7),
            (workspaceId: w2, surfaceId: s2, ttyDevice: 9),
        ]
        XCTAssertEqual(
            agentDeliveryTargetMatchingTTYDevice(7, surfaceTTYDevices: bindings),
            AgentDeliveryTargetCandidate(workspaceId: w1, surfaceId: s1)
        )
        XCTAssertNil(agentDeliveryTargetMatchingTTYDevice(5, surfaceTTYDevices: bindings))
        XCTAssertNil(
            agentDeliveryTargetMatchingTTYDevice(
                7,
                surfaceTTYDevices: bindings + [(workspaceId: w2, surfaceId: s2, ttyDevice: 7)]
            ),
            "A tty device claimed by two different surfaces must refuse to guess"
        )
        XCTAssertEqual(
            agentDeliveryTargetMatchingTTYDevice(
                7,
                surfaceTTYDevices: bindings + [(workspaceId: w1, surfaceId: s1, ttyDevice: 7)]
            )?.surfaceId,
            s1,
            "Consistent duplicate rows for the same surface still resolve"
        )
    }
}
