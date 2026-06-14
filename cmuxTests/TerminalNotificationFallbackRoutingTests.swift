import XCTest
import AppKit
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalNotificationFallbackRoutingTests: TerminalNotificationSocketTestCase {
    func testNotificationOpenDoesNotFallbackToUnrelatedWindowContext() async throws {
        let fixture = try makeSocketFixture(name: "notif-open-unowned")
        defer { fixture.cleanup() }

        let unrelatedManager = TabManager()
        let unrelatedWindowId = fixture.appDelegate.registerMainWindowContextForTesting(tabManager: unrelatedManager)
        let unrelatedWindow = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        unrelatedWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(unrelatedWindowId.uuidString)")
        unrelatedWindow.makeKeyAndOrderFront(nil)
        defer {
            unrelatedWindow.close()
            fixture.appDelegate.unregisterMainWindowContextForTesting(windowId: unrelatedWindowId)
            for workspace in unrelatedManager.tabs {
                unrelatedManager.closeWorkspace(workspace)
            }
        }

        let selectedWorkspace = fixture.workspace
        let targetWorkspace = fixture.manager.addWorkspace(title: "Unowned Notification", select: false)
        let targetSurfaceId = try XCTUnwrap(targetWorkspace.focusedPanelId)
        let notification = makeNotification(tabId: targetWorkspace.id, surfaceId: targetSurfaceId, title: "Unowned")
        fixture.store.replaceNotificationsForTesting([notification])
        fixture.manager.selectTab(selectedWorkspace)

        let response = try await sendV2RequestAsync(
            method: "notification.open",
            params: ["id": notification.id.uuidString],
            to: fixture.socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "\(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "not_found")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["opened"] as? Bool, false)
        XCTAssertEqual(fixture.manager.selectedTabId, selectedWorkspace.id)
        XCTAssertEqual(fixture.notification(notification.id)?.isRead, false)
    }
}
