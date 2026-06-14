import AppKit
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TerminalNotificationFallbackRoutingTests {
    private let socketTestSupport = TerminalNotificationSocketTestCase()

    @Test
    func notificationOpenDoesNotFallbackToUnrelatedWindowContext() async throws {
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
        let targetSurfaceId = try #require(targetWorkspace.focusedPanelId)
        let notification = makeNotification(tabId: targetWorkspace.id, surfaceId: targetSurfaceId, title: "Unowned")
        fixture.store.replaceNotificationsForTesting([notification])
        fixture.manager.selectTab(selectedWorkspace)

        let response = try await sendV2RequestAsync(
            method: "notification.open",
            params: ["id": notification.id.uuidString],
            to: fixture.socketPath
        )

        #expect(response["ok"] as? Bool == false)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? String == "not_found")
        let data = try #require(error["data"] as? [String: Any])
        #expect(data["opened"] as? Bool == false)
        #expect(fixture.manager.selectedTabId == selectedWorkspace.id)
        #expect(fixture.notification(notification.id)?.isRead == false)
    }
}

private extension TerminalNotificationFallbackRoutingTests {
    func makeSocketFixture(
        name: String,
        includeWindow: Bool = false
    ) throws -> TerminalNotificationSocketTestCase.SocketFixture {
        try socketTestSupport.makeSocketFixture(name: name, includeWindow: includeWindow)
    }

    func makeNotification(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        isRead: Bool = false
    ) -> TerminalNotification {
        socketTestSupport.makeNotification(tabId: tabId, surfaceId: surfaceId, title: title, isRead: isRead)
    }

    func sendV2RequestAsync(
        method: String,
        params: [String: Any] = [:],
        to socketPath: String
    ) async throws -> [String: Any] {
        try await socketTestSupport.sendV2RequestAsync(method: method, params: params, to: socketPath)
    }
}
