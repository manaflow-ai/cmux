@preconcurrency import XCTest
import Foundation

// Stays on XCTest deliberately: these cases extend the existing socket-action
// suite and reuse its process-safe fixture/server lifecycle.
extension TerminalNotificationSocketActionTests {
    func testNotificationCreateForCallerPrefersPreferredSurfaceOverConflictingTTY() async throws {
        let fixture = try makeSocketFixture(name: "notify-surface-over-tty")
        defer { fixture.cleanup() }

        let fallbackWorkspace = fixture.workspace
        let targetWorkspace = fixture.manager.addWorkspace(title: "Preferred Surface", select: false)
        let targetSurfaceId = try XCTUnwrap(targetWorkspace.focusedPanelId)

        // This is deliberately stale/unproven metadata. The old dictionary
        // scan returned the focused fallback pane before considering the
        // preferred surface; strict resolution must let the surface identity
        // win when no explicit TTY preference is requested.
        fallbackWorkspace.surfaceTTYNames[fixture.surfaceId] = "/dev/ttys777"
        let response = try await sendV2RequestAsync(
            method: "notification.create_for_caller",
            params: [
                "preferred_workspace_id": UUID().uuidString,
                "preferred_surface_id": targetSurfaceId.uuidString,
                "caller_tty": "/dev/ttys777",
                "prefer_tty": false,
                "title": "Preferred surface",
                "subtitle": "Evidence",
                "body": "Surface identity wins"
            ],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["workspace_id"] as? String, targetWorkspace.id.uuidString)
        XCTAssertEqual(result["surface_id"] as? String, targetSurfaceId.uuidString)
        XCTAssertTrue(fixture.store.hasUnreadNotification(forTabId: targetWorkspace.id, surfaceId: targetSurfaceId))
        XCTAssertFalse(fixture.store.hasUnreadNotification(forTabId: fallbackWorkspace.id, surfaceId: fixture.surfaceId))
    }

    func testNotificationCreateForCallerRejectsAmbiguousReportedTTY() async throws {
        let fixture = try makeSocketFixture(name: "notify-ambiguous-tty")
        defer { fixture.cleanup() }

        let focusedSurfaceId = fixture.surfaceId
        let siblingPanel = try XCTUnwrap(
            fixture.workspace.newTerminalSplit(
                from: focusedSurfaceId,
                orientation: .horizontal,
                focus: false
            )
        )
        let ambiguousTTY = "/dev/ttys777"
        fixture.workspace.registerReportedSurfaceTTYName(ambiguousTTY, panelId: focusedSurfaceId)
        fixture.workspace.registerReportedSurfaceTTYName(ambiguousTTY, panelId: siblingPanel.id)

        let response = try await sendV2RequestAsync(
            method: "notification.create_for_caller",
            params: [
                "caller_tty": ambiguousTTY,
                "prefer_tty": false,
                "title": "Ambiguous",
                "subtitle": "TTY",
                "body": "Must fail closed"
            ],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "\(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "not_found")
        XCTAssertFalse(fixture.store.hasUnreadNotification(forTabId: fixture.workspace.id, surfaceId: focusedSurfaceId))
        XCTAssertFalse(fixture.store.hasUnreadNotification(forTabId: fixture.workspace.id, surfaceId: siblingPanel.id))
    }
}
