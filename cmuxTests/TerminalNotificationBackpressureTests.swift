import Foundation
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class NotificationEnqueueResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func append(_ value: Bool) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@MainActor
final class TerminalNotificationBackpressureTests: XCTestCase {
    func testSaturationCapsWaitersBeforeAcceptanceAndPreservesAcceptedFIFO() async {
        let bus = TerminalMutationBus.shared
        let tabId = UUID()
        let surfaceId = UUID()
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.discardPendingNotifications()
            bus.drainForTesting()
            bus.setDrainsSuspendedForTesting(false)
        }

        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: tabId,
                surfaceId: surfaceId,
                title: "Seed \(index)",
                subtitle: "",
                body: ""
            ))
        }

        let started = expectation(description: "waiting producers started")
        started.expectedFulfillmentCount = TerminalMutationBus.maximumWaitingNotificationProducerCount
        let completed = expectation(description: "waiting producers completed")
        completed.expectedFulfillmentCount = TerminalMutationBus.maximumWaitingNotificationProducerCount
        let results = NotificationEnqueueResults()
        let expectedWaiterTitles = Set(
            (0..<TerminalMutationBus.maximumWaitingNotificationProducerCount).map { "Waiter \($0)" }
        )

        for index in 0..<TerminalMutationBus.maximumWaitingNotificationProducerCount {
            DispatchQueue.global(qos: .userInitiated).async {
                started.fulfill()
                results.append(bus.enqueueNotification(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    title: "Waiter \(index)",
                    subtitle: "",
                    body: ""
                ))
                completed.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 2)
        for _ in 0..<10_000 {
            if bus.notificationQueueStateForTesting().0 == TerminalMutationBus.maximumWaitingNotificationProducerCount {
                break
            }
            await Task.yield()
        }

        let fullState = bus.notificationQueueStateForTesting()
        XCTAssertEqual(fullState.0, TerminalMutationBus.maximumWaitingNotificationProducerCount)
        XCTAssertEqual(fullState.1.count, TerminalMutationBus.maximumPendingMutationCount)
        XCTAssertFalse(bus.enqueueNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Rejected before acceptance",
            subtitle: "",
            body: ""
        ))
        XCTAssertEqual(bus.notificationQueueStateForTesting().1, fullState.1)

        bus.discardPendingNotifications()
        await fulfillment(of: [completed], timeout: 2)

        let acceptedState = bus.notificationQueueStateForTesting()
        XCTAssertEqual(results.snapshot(), Array(repeating: true, count: expectedWaiterTitles.count))
        XCTAssertEqual(Set(acceptedState.1), expectedWaiterTitles)
        XCTAssertEqual(acceptedState.1.count, expectedWaiterTitles.count)
        XCTAssertEqual(acceptedState.2, acceptedState.2.sorted())
        XCTAssertEqual(Set(acceptedState.2).count, acceptedState.2.count)
    }

    func testCapacityWaitExpiresBeforeNotificationAcceptance() async {
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            bus.discardPendingNotifications()
            bus.drainForTesting()
            bus.setDrainsSuspendedForTesting(false)
        }
        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: UUID(), surfaceId: nil, title: "Seed \(index)", subtitle: "", body: ""
            ))
        }

        let completed = expectation(description: "capacity wait expired")
        let results = NotificationEnqueueResults()
        DispatchQueue.global(qos: .userInitiated).async {
            results.append(bus.enqueueNotification(
                tabId: UUID(), surfaceId: nil, title: "Timed out", subtitle: "", body: ""
            ))
            completed.fulfill()
        }
        for _ in 0..<10_000 {
            if bus.notificationQueueStateForTesting().0 == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(bus.notificationQueueStateForTesting().0, 1)
        await fulfillment(of: [completed], timeout: TerminalMutationBus.notificationCapacityWaitTimeout + 1)
        XCTAssertEqual(results.snapshot(), [false])
        XCTAssertEqual(bus.notificationQueueStateForTesting().0, 0)
        XCTAssertFalse(bus.notificationQueueStateForTesting().1.contains("Timed out"))
    }
}

@MainActor
final class TerminalNotificationSessionReplacementTests: XCTestCase {
    func testReplacementTransfersLiveAndRestoredNotificationsToRebuiltTargets() {
        let store = TerminalNotificationStore.shared
        let bus = TerminalMutationBus.shared
        let oldTabId = UUID()
        let newTabId = UUID()
        let oldSurfaceId = UUID()
        let newSurfaceId = UUID()
        let restoredId = UUID()
        let lateId = UUID()
        let duringReleaseId = UUID()
        let unrelatedTabId = UUID()
        let unrelatedSurfaceId = UUID()
        let unrelatedId = UUID()
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            store.replaceNotificationsForTesting([])
            bus.discardPendingNotifications()
            bus.drainForTesting()
            bus.setDrainsSuspendedForTesting(false)
        }

        let liveCanonical = notification(
            id: restoredId,
            tabId: oldTabId,
            surfaceId: oldSurfaceId,
            title: "Live canonical",
            createdAt: Date(timeIntervalSince1970: 20),
            isRead: true
        )
        let lateLive = notification(
            id: lateId,
            tabId: oldTabId,
            surfaceId: oldSurfaceId,
            title: "Late live",
            createdAt: Date(timeIntervalSince1970: 30),
            isRead: false
        )
        let unrelated = notification(
            id: unrelatedId,
            tabId: unrelatedTabId,
            surfaceId: unrelatedSurfaceId,
            title: "Unrelated",
            createdAt: Date(timeIntervalSince1970: 5),
            isRead: false
        )
        store.replaceNotificationsForTesting([liveCanonical, lateLive, unrelated])

        let restoredReplay = notification(
            id: restoredId,
            tabId: newTabId,
            surfaceId: newSurfaceId,
            title: "Persisted replay",
            createdAt: Date(timeIntervalSince1970: 10),
            isRead: false
        )
        store.restoreSessionNotifications(
            [restoredReplay],
            forTabId: newTabId,
            replacingTabId: oldTabId,
            panelIdMap: [oldSurfaceId: newSurfaceId]
        )
        let duringRelease = notification(
            id: duringReleaseId,
            tabId: oldTabId,
            surfaceId: oldSurfaceId,
            title: "During release",
            createdAt: Date(timeIntervalSince1970: 40),
            isRead: false
        )
        store.replaceNotificationsForTesting(store.notifications + [duringRelease])
        store.markUnread(forTabId: oldTabId)
        store.setPanelDerivedUnread(true, forTabId: oldTabId)
        store.restoreUnreadIndicator(forTabId: oldTabId)
        store.setFocusedReadIndicator(forTabId: oldTabId, surfaceId: oldSurfaceId)
        store.markUnread(forTabId: unrelatedTabId)
        store.setFocusedReadIndicator(forTabId: unrelatedTabId, surfaceId: unrelatedSurfaceId)
        XCTAssertTrue(bus.enqueueNotification(
            tabId: oldTabId,
            surfaceId: oldSurfaceId,
            title: "Accepted during restore",
            subtitle: "",
            body: ""
        ))
        let queuedBeforeTransfer = bus.notificationIdentityStateForTesting()
        store.transferSessionNotifications(
            fromTabId: oldTabId,
            toTabId: newTabId,
            panelIdMap: [oldSurfaceId: newSurfaceId]
        )
        let queuedAfterTransfer = bus.notificationIdentityStateForTesting()

        XCTAssertEqual(store.notifications.map(\.id), [duringReleaseId, lateId, restoredId, unrelatedId])
        XCTAssertEqual(store.notifications.first(where: { $0.id == restoredId })?.title, "Live canonical")
        XCTAssertEqual(store.notifications.first(where: { $0.id == restoredId })?.isRead, true)
        XCTAssertEqual(store.notifications.first(where: { $0.id == restoredId })?.tabId, newTabId)
        XCTAssertEqual(store.notifications.first(where: { $0.id == restoredId })?.surfaceId, newSurfaceId)
        XCTAssertEqual(store.notifications.first(where: { $0.id == lateId })?.tabId, newTabId)
        XCTAssertEqual(store.notifications.first(where: { $0.id == lateId })?.surfaceId, newSurfaceId)
        XCTAssertEqual(store.notifications.first(where: { $0.id == duringReleaseId })?.tabId, newTabId)
        XCTAssertEqual(store.notifications.first(where: { $0.id == duringReleaseId })?.surfaceId, newSurfaceId)
        XCTAssertEqual(store.notifications.first(where: { $0.id == unrelatedId }), unrelated)
        XCTAssertEqual(Set(store.notifications.map(\.id)).count, store.notifications.count)
        XCTAssertEqual(queuedBeforeTransfer.count, 1)
        XCTAssertEqual(queuedAfterTransfer.count, 1)
        XCTAssertEqual(queuedAfterTransfer[0].0, queuedBeforeTransfer[0].0)
        XCTAssertEqual(queuedAfterTransfer[0].1, queuedBeforeTransfer[0].1)
        XCTAssertEqual(queuedAfterTransfer[0].4, queuedBeforeTransfer[0].4)
        XCTAssertEqual(queuedAfterTransfer[0].2, newTabId)
        XCTAssertEqual(queuedAfterTransfer[0].3, newSurfaceId)
        XCTAssertFalse(store.hasManualUnread(forTabId: oldTabId))
        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: oldTabId))
        XCTAssertFalse(store.hasRestoredUnreadIndicator(forTabId: oldTabId))
        XCTAssertNil(store.focusedReadIndicatorSurfaceId(forTabId: oldTabId))
        XCTAssertTrue(store.hasManualUnread(forTabId: newTabId))
        XCTAssertTrue(store.hasPanelDerivedUnread(forTabId: newTabId))
        XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: newTabId))
        XCTAssertEqual(store.focusedReadIndicatorSurfaceId(forTabId: newTabId), newSurfaceId)
        XCTAssertTrue(store.hasManualUnread(forTabId: unrelatedTabId))
        XCTAssertEqual(store.focusedReadIndicatorSurfaceId(forTabId: unrelatedTabId), unrelatedSurfaceId)
    }

    func testReplacementRemapsQueuedSurfaceAndWorkspaceClears() {
        let store = TerminalNotificationStore.shared
        let bus = TerminalMutationBus.shared
        let oldTabId = UUID()
        let newTabId = UUID()
        let oldSurfaceId = UUID()
        let newSurfaceId = UUID()
        let survivingSurfaceId = UUID()
        let unrelatedTabId = UUID()
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer {
            store.replaceNotificationsForTesting([])
            bus.discardPendingNotifications()
            bus.drainForTesting()
            bus.setDrainsSuspendedForTesting(false)
        }

        let clearedBySurface = notification(
            id: UUID(), tabId: newTabId, surfaceId: newSurfaceId,
            title: "Surface", createdAt: Date(timeIntervalSince1970: 3), isRead: false
        )
        let clearedByWorkspace = notification(
            id: UUID(), tabId: newTabId, surfaceId: survivingSurfaceId,
            title: "Workspace", createdAt: Date(timeIntervalSince1970: 2), isRead: false
        )
        let unrelated = notification(
            id: UUID(), tabId: unrelatedTabId, surfaceId: UUID(),
            title: "Unrelated", createdAt: Date(timeIntervalSince1970: 1), isRead: false
        )
        store.replaceNotificationsForTesting([clearedBySurface, clearedByWorkspace, unrelated])

        bus.enqueueClearNotifications(forTabId: oldTabId, surfaceId: oldSurfaceId)
        store.transferSessionNotifications(
            fromTabId: oldTabId,
            toTabId: newTabId,
            panelIdMap: [oldSurfaceId: newSurfaceId]
        )
        bus.drainForTesting()
        XCTAssertEqual(store.notifications.map(\.id), [clearedByWorkspace.id, unrelated.id])

        bus.enqueueClearNotifications(forTabId: oldTabId)
        store.transferSessionNotifications(
            fromTabId: oldTabId,
            toTabId: newTabId,
            panelIdMap: [oldSurfaceId: newSurfaceId]
        )
        bus.drainForTesting()
        XCTAssertEqual(store.notifications, [unrelated])
    }

    private func notification(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID,
        title: String,
        createdAt: Date,
        isRead: Bool
    ) -> TerminalNotification {
        TerminalNotification(
            id: id,
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: "",
            body: "",
            createdAt: createdAt,
            isRead: isRead
        )
    }
}
