import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Dynamic Notch notification tray")
struct DynamicNotchNotificationTrayModelTests {
    @Test("Notifications accumulate newest first and resolve independently")
    func notificationsAccumulateAndResolveIndependently() {
        let model = DynamicNotchNotificationTrayModel()
        let first = makeNotification(title: "First")
        let second = makeNotification(title: "Second")

        #expect(model.enqueue(first))
        #expect(model.enqueue(second))
        #expect(model.notifications.map(\.id) == [second.id, first.id])

        model.setExpanded(true)
        #expect(model.isExpanded)
        #expect(model.remove(id: second.id) == second)
        #expect(model.notifications == [first])
        #expect(model.isExpanded)

        #expect(model.remove(id: first.id) == first)
        #expect(model.notifications.isEmpty)
        #expect(!model.isExpanded)
    }

    @Test("Duplicate notification identifiers do not create duplicate rows")
    func duplicateIdentifiersAreIgnored() {
        let model = DynamicNotchNotificationTrayModel()
        let notification = makeNotification(title: "Approval")

        #expect(model.enqueue(notification))
        #expect(!model.enqueue(notification))
        #expect(model.notifications == [notification])
    }

    private func makeNotification(title: String) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: UUID(),
            title: title,
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )
    }
}
