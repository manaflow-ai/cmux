import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class NotificationSessionReplacementIdentityTests: XCTestCase {
    func testReplacementRetainsUnmappedNotificationLocation() throws {
        let oldTabId = UUID()
        let newTabId = UUID()
        let unmappedSurfaceId = UUID()
        let unmappedPanelId = UUID()
        let current = TerminalNotification(
            id: UUID(),
            tabId: oldTabId,
            surfaceId: unmappedSurfaceId,
            panelId: unmappedPanelId,
            title: "Unmapped surface",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 1),
            isRead: false
        )

        let merged = TerminalNotificationStore.mergeRestoredSessionNotifications(
            existing: [current],
            restored: [],
            tabId: newTabId,
            replacingTabId: oldTabId,
            panelIdMap: [:]
        )
        let transferred = try XCTUnwrap(merged.first)

        XCTAssertEqual(transferred.tabId, newTabId)
        XCTAssertEqual(transferred.surfaceId, unmappedSurfaceId)
        XCTAssertEqual(transferred.panelId, unmappedPanelId)
    }

    func testReplacementRetainsUnmappedFocusedAndQueuedSurfaceIdentity() throws {
        let store = TerminalNotificationStore.shared
        let bus = TerminalMutationBus.shared
        let oldTabId = UUID()
        let newTabId = UUID()
        let unmappedSurfaceId = UUID()
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        store.replaceNotificationsForTesting([])
        defer {
            store.replaceNotificationsForTesting([])
            bus.discardPendingNotifications()
            bus.drainForTesting()
            bus.setDrainsSuspendedForTesting(false)
        }

        store.setFocusedReadIndicator(forTabId: oldTabId, surfaceId: unmappedSurfaceId)
        XCTAssertTrue(bus.enqueueNotification(
            tabId: oldTabId,
            surfaceId: unmappedSurfaceId,
            title: "Accepted before replacement",
            subtitle: "",
            body: ""
        ))

        store.transferSessionNotifications(
            fromTabId: oldTabId,
            toTabId: newTabId,
            panelIdMap: [:]
        )

        let queued = try XCTUnwrap(bus.notificationIdentityStateForTesting().first)
        XCTAssertEqual(queued.2, newTabId)
        XCTAssertEqual(queued.3, unmappedSurfaceId)
        XCTAssertEqual(store.focusedReadIndicatorSurfaceId(forTabId: newTabId), unmappedSurfaceId)
    }
}
