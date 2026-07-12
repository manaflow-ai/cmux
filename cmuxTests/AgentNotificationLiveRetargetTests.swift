import AppKit
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
