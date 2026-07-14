import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class NotificationSessionReplacementIdentityTests: XCTestCase {
    func testDuplicateRestoreCanonicalizationIncludesRoutingAndScrollFields() throws {
        let tabId = UUID()
        let notificationId = UUID()
        let createdAt = Date(timeIntervalSince1970: 1)

        func notification(
            retargetsToLiveSurfaceOwner: Bool = true,
            rowSpaceRevision: UInt64? = nil
        ) -> TerminalNotification {
            TerminalNotification(
                id: notificationId,
                tabId: tabId,
                surfaceId: nil,
                retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
                title: "Duplicate",
                subtitle: "",
                body: "",
                createdAt: createdAt,
                isRead: false,
                scrollPosition: TerminalNotificationScrollPosition(
                    row: 1,
                    totalRows: 2,
                    rowSpaceRevision: rowSpaceRevision
                )
            )
        }

        func canonical(_ restored: [TerminalNotification]) throws -> TerminalNotification {
            try XCTUnwrap(TerminalNotificationStore.mergeRestoredSessionNotifications(
                existing: [],
                restored: restored,
                tabId: tabId,
                replacingTabId: nil,
                panelIdMap: [:]
            ).first)
        }

        let confined = notification(retargetsToLiveSurfaceOwner: false)
        let retargeting = notification(retargetsToLiveSurfaceOwner: true)
        XCTAssertEqual(
            try canonical([confined, retargeting]),
            try canonical([retargeting, confined])
        )

        let earlierRowSpace = notification(rowSpaceRevision: 1)
        let laterRowSpace = notification(rowSpaceRevision: 2)
        XCTAssertEqual(
            try canonical([earlierRowSpace, laterRowSpace]),
            try canonical([laterRowSpace, earlierRowSpace])
        )
    }

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
