import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct TerminalControllerMobileNotificationsTests {
    @Test
    func testMobileRecentNotificationsKeepsBoundedStoreOrderWindow() {
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
        #expect(Array(recent.map(\.title).prefix(3)) == ["N0", "N1", "N2"])
        #expect(Array(recent.map(\.title).suffix(3)) == ["N197", "N198", "N199"])
        #expect(!recent.contains { ["N200", "N201", "N202", "N203", "N204"].contains($0.title) })
    }
}
