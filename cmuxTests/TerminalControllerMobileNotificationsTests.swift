import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct TerminalControllerMobileNotificationsTests {
    @Test
    func testMobileRecentNotificationsKeepsBoundedChronologicalWindow() {
        let notifications = (0..<205).map { index in
            TerminalNotification(
                id: UUID(),
                tabId: UUID(),
                surfaceId: nil,
                title: "N\(index)",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: false
            )
        }

        let recent = TerminalController.mobileRecentNotifications(notifications, limit: 200)

        #expect(recent.count == 200)
        #expect(Array(recent.map(\.title).prefix(3)) == ["N204", "N203", "N202"])
        #expect(Array(recent.map(\.title).suffix(3)) == ["N7", "N6", "N5"])
        #expect(!recent.contains { ["N0", "N1", "N2", "N3", "N4"].contains($0.title) })
    }

    @Test
    func testMobileRecentNotificationsIgnoresUnreadPresentationReorder() {
        let workspaceId = UUID()
        let older = TerminalNotification(
            id: UUID(),
            tabId: workspaceId,
            surfaceId: nil,
            title: "older",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 10),
            isRead: false
        )
        let newestMovedBehindOlderUnread = TerminalNotification(
            id: UUID(),
            tabId: workspaceId,
            surfaceId: nil,
            title: "newest",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 20),
            isRead: false
        )
        let storeOrderedForMenu = [older, newestMovedBehindOlderUnread]

        let recent = TerminalController.mobileRecentNotifications(storeOrderedForMenu, limit: 1)

        #expect(recent.map(\.title) == ["newest"])
    }
}
