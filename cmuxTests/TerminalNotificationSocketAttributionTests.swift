@preconcurrency import XCTest
import Foundation
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Stays on XCTest deliberately: these cases extend the existing socket-action
// suite and reuse its process-safe fixture/server lifecycle.
extension TerminalNotificationSocketActionTests {
    func testNotificationCreateForCallerKeepsExplicitWorkspaceOverForeignAmbientSurface() async throws {
        let fixture = try makeSocketFixture(name: "notify-workspace-scope")
        defer { fixture.cleanup() }

        let foreignWorkspace = fixture.manager.addWorkspace(title: "Foreign Surface", select: false)
        let foreignSurfaceId = try XCTUnwrap(foreignWorkspace.focusedPanelId)
        let response = try await sendV2RequestAsync(
            method: "notification.create_for_caller",
            params: [
                "preferred_workspace_id": fixture.workspace.id.uuidString,
                "preferred_workspace_is_explicit": true,
                "preferred_surface_id": foreignSurfaceId.uuidString,
                "prefer_tty": false,
                "title": "Workspace scope",
                "subtitle": "Evidence",
                "body": "No foreign pane ring"
            ],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["workspace_id"] as? String, fixture.workspace.id.uuidString)
        XCTAssertTrue(result["surface_id"] is NSNull)
        XCTAssertTrue(fixture.store.hasUnreadNotification(forTabId: fixture.workspace.id, surfaceId: nil))
        XCTAssertFalse(fixture.store.hasUnreadNotification(forTabId: foreignWorkspace.id, surfaceId: foreignSurfaceId))
    }

    func testNotificationCreateForCallerRehomesSurfacePastAmbientWorkspaceClaim() async throws {
        let fixture = try makeSocketFixture(name: "notify-ambient-rehome")
        defer { fixture.cleanup() }

        let movedWorkspace = fixture.manager.addWorkspace(title: "Moved Surface", select: false)
        let movedSurfaceId = try XCTUnwrap(movedWorkspace.focusedPanelId)
        let response = try await sendV2RequestAsync(
            method: "notification.create_for_caller",
            params: [
                "preferred_workspace_id": fixture.workspace.id.uuidString,
                "preferred_workspace_is_explicit": false,
                "preferred_surface_id": movedSurfaceId.uuidString,
                "prefer_tty": false,
                "title": "Ambient rehome",
                "subtitle": "Evidence",
                "body": "Follow the stable pane"
            ],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["workspace_id"] as? String, movedWorkspace.id.uuidString)
        XCTAssertEqual(result["surface_id"] as? String, movedSurfaceId.uuidString)
        XCTAssertTrue(fixture.store.hasUnreadNotification(forTabId: movedWorkspace.id, surfaceId: movedSurfaceId))
        XCTAssertFalse(fixture.store.hasUnreadNotification(forTabId: fixture.workspace.id, surfaceId: fixture.surfaceId))
    }

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
        let fixture = try makeSocketFixture(
            name: "notify-ambiguous-tty",
            eagerLoadTerminal: true
        )
        defer { fixture.cleanup() }

        let focusedSurfaceId = fixture.surfaceId
        let siblingPanel = try XCTUnwrap(
            fixture.workspace.newTerminalSplit(
                from: focusedSurfaceId,
                orientation: .horizontal,
                focus: false
            )
        )
        let temporaryPanel = try XCTUnwrap(
            fixture.workspace.newTerminalSplit(
                from: siblingPanel.id,
                orientation: .horizontal,
                focus: false
            )
        )
        // Keep a real, session-valid TTY name for PortScanner freshness, but
        // detach its panel so no live runtime candidate owns that name. The
        // two remaining panels then exercise the reported-TTY ambiguity tier.
        let temporaryTransfer = try XCTUnwrap(
            fixture.workspace.detachSurface(panelId: temporaryPanel.id)
        )
        let temporaryTerminal = try XCTUnwrap(temporaryTransfer.panel as? TerminalPanel)
        let ambiguousTTY = try await TerminalControllingTTYWaiter().wait(for: temporaryTerminal)
        fixture.workspace.registerReportedSurfaceTTYName(ambiguousTTY, panelId: focusedSurfaceId)
        fixture.workspace.registerReportedSurfaceTTYName(ambiguousTTY, panelId: siblingPanel.id)
        PortScanner.shared.registerTTY(
            workspaceId: fixture.workspace.id,
            panelId: focusedSurfaceId,
            ttyName: ambiguousTTY
        )
        PortScanner.shared.registerTTY(
            workspaceId: fixture.workspace.id,
            panelId: siblingPanel.id,
            ttyName: ambiguousTTY
        )

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

    func testNotificationCreateForCallerKeepsExplicitWorkspaceWhenPreferredTTYIsForeign() async throws {
        let fixture = try makeSocketFixture(
            name: "notify-explicit-tty-scope",
            eagerLoadTerminal: true
        )
        defer { fixture.cleanup() }

        let foreignWorkspace = fixture.manager.addWorkspace(
            title: "Foreign TTY",
            select: false,
            eagerLoadTerminal: true
        )
        let foreignSurfaceId = try XCTUnwrap(foreignWorkspace.focusedPanelId)
        let foreignTerminal = try XCTUnwrap(
            foreignWorkspace.panels[foreignSurfaceId] as? TerminalPanel
        )
        let foreignTTY = try await TerminalControllingTTYWaiter().wait(for: foreignTerminal)

        let response = try await sendV2RequestAsync(
            method: "notification.create_for_caller",
            params: [
                "preferred_workspace_id": fixture.workspace.id.uuidString,
                "preferred_workspace_is_explicit": true,
                "caller_tty": foreignTTY,
                "prefer_tty": true,
                "title": "Explicit workspace",
                "subtitle": "TTY scope",
                "body": "Do not cross the requested workspace"
            ],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["workspace_id"] as? String, fixture.workspace.id.uuidString)
        XCTAssertTrue(result["surface_id"] is NSNull)
        XCTAssertTrue(fixture.store.hasUnreadNotification(forTabId: fixture.workspace.id, surfaceId: nil))
        XCTAssertFalse(
            fixture.store.hasUnreadNotification(
                forTabId: foreignWorkspace.id,
                surfaceId: foreignSurfaceId
            )
        )
    }

    #if DEBUG
    func testDebugNotificationRejectsMalformedCallerSelector() async throws {
        let fixture = try makeSocketFixture(name: "notify-debug-selector")
        defer { fixture.cleanup() }

        let response = try await sendV2RequestAsync(
            method: "debug.notification.emit",
            params: [
                "kind": "feed-question",
                "preferred_surface_id": "not-a-surface-ref"
            ],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "\(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_params")
        XCTAssertTrue(fixture.store.notifications.isEmpty)
    }
    #endif
}
