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
    func testSaturationCapsWaitersBeforeAcceptance() async {
        let bus = TerminalMutationBus.shared
        let tabId = UUID()
        let surfaceId = UUID()
        resetBackpressureQueueState(bus)
        bus.setDrainsSuspendedForTesting(true)
        defer {
            resetBackpressureQueueState(bus)
        }

        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: tabId,
                surfaceId: surfaceId,
                title: "",
                subtitle: "",
                body: ""
            ), "Seed \(index) should be admitted before the count cap")
        }

        let ready = DispatchGroup()
        let releaseWaiters = DispatchSemaphore(value: 0)
        let completed = expectation(description: "waiting producers completed")
        completed.expectedFulfillmentCount = TerminalMutationBus.maximumWaitingNotificationProducerCount
        let results = NotificationEnqueueResults()
        let expectedWaiterTitles = Set(
            (0..<TerminalMutationBus.maximumWaitingNotificationProducerCount).map { "Waiter \($0)" }
        )

        for index in 0..<TerminalMutationBus.maximumWaitingNotificationProducerCount {
            ready.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                ready.leave()
                releaseWaiters.wait()
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
        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
        for _ in 0..<TerminalMutationBus.maximumWaitingNotificationProducerCount {
            releaseWaiters.signal()
        }
        XCTAssertTrue(waitForWaitingNotificationProducers(bus, count: TerminalMutationBus.maximumWaitingNotificationProducerCount))

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

        XCTAssertEqual(results.snapshot(), Array(repeating: true, count: expectedWaiterTitles.count))
    }

    private func waitForWaitingNotificationProducers(
        _ bus: TerminalMutationBus,
        count: Int
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: TerminalMutationBus.notificationCapacityWaitTimeout / 2)
        while Date() < deadline {
            if bus.notificationQueueStateForTesting().0 == count {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
        return bus.notificationQueueStateForTesting().0 == count
    }

    func testCapacityWaitExpiresBeforeNotificationAcceptance() async {
        let bus = TerminalMutationBus.shared
        resetBackpressureQueueState(bus)
        bus.setDrainsSuspendedForTesting(true)
        defer {
            resetBackpressureQueueState(bus)
        }
        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: UUID(), surfaceId: nil, title: "", subtitle: "", body: ""
            ), "Seed \(index) should be admitted before the count cap")
        }

        let completed = expectation(description: "capacity wait expired")
        let results = NotificationEnqueueResults()
        DispatchQueue.global(qos: .userInitiated).async {
            results.append(bus.enqueueNotification(
                tabId: UUID(), surfaceId: nil, title: "Timed out", subtitle: "", body: ""
            ))
            completed.fulfill()
        }
        XCTAssertTrue(waitForWaitingNotificationProducers(bus, count: 1))
        XCTAssertEqual(bus.notificationQueueStateForTesting().0, 1)
        await fulfillment(of: [completed], timeout: TerminalMutationBus.notificationCapacityWaitTimeout + 1)
        XCTAssertEqual(results.snapshot(), [false])
        XCTAssertEqual(bus.notificationQueueStateForTesting().0, 0)
        XCTAssertFalse(bus.notificationQueueStateForTesting().1.contains("Timed out"))
    }

    func testQueuedContentByteBudgetRejectsBeforePendingCountLimit() {
        let bus = TerminalMutationBus.shared
        let body = String(repeating: "b", count: TerminalNotificationStore.maximumNotificationBodyBytes)
        let byteLimitedCount = TerminalMutationBus.maximumQueuedNotificationContentBytes / body.utf8.count
        XCTAssertLessThan(byteLimitedCount, TerminalMutationBus.maximumPendingMutationCount)
        resetBackpressureQueueState(bus)
        bus.setDrainsSuspendedForTesting(true)
        defer {
            resetBackpressureQueueState(bus)
        }

        for _ in 0..<byteLimitedCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: UUID(),
                surfaceId: nil,
                title: "",
                subtitle: "",
                body: body
            ))
        }

        XCTAssertEqual(bus.notificationIdentityStateForTesting().count, byteLimitedCount)
        XCTAssertFalse(bus.enqueueNotification(
            tabId: UUID(),
            surfaceId: nil,
            title: "",
            subtitle: "",
            body: body
        ))
        XCTAssertEqual(bus.notificationIdentityStateForTesting().count, byteLimitedCount)
    }

    func testOversizedQueuedTextIsTruncatedBeforePendingAdmission() {
        let bus = TerminalMutationBus.shared
        let title = String(repeating: "é", count: TerminalNotificationStore.maximumNotificationTitleBytes)
        let subtitle = String(repeating: "s", count: TerminalNotificationStore.maximumNotificationSubtitleBytes + 128)
        let body = String(repeating: "b", count: TerminalNotificationStore.maximumNotificationBodyBytes + 128)
        resetBackpressureQueueState(bus)
        bus.setDrainsSuspendedForTesting(true)
        defer {
            resetBackpressureQueueState(bus)
        }

        XCTAssertTrue(bus.enqueueNotification(
            tabId: UUID(),
            surfaceId: nil,
            title: title,
            subtitle: subtitle,
            body: body
        ))

        let queuedTitles = bus.notificationQueueStateForTesting().1
        XCTAssertEqual(queuedTitles.count, 1)
        XCTAssertLessThanOrEqual(queuedTitles[0].utf8.count, TerminalNotificationStore.maximumNotificationTitleBytes)
    }

    func testSharedAgentDeliveryReportsSaturationBeforeAcceptance() {
        let bus = TerminalMutationBus.shared
        resetBackpressureQueueState(bus)
        bus.setDrainsSuspendedForTesting(true)
        defer {
            resetBackpressureQueueState(bus)
        }
        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: UUID(), surfaceId: nil, title: "Seed \(index)", subtitle: "", body: ""
            ))
        }

        let result = AgentNotificationDelivery().enqueue(
            workspaceID: UUID(),
            surfaceID: UUID(),
            title: "Rejected by shared delivery",
            subtitle: "",
            body: "",
            category: nil,
            pending: false
        )

        XCTAssertEqual(result, .saturated)
        XCTAssertFalse(bus.notificationQueueStateForTesting().1.contains("Rejected by shared delivery"))
    }

    func testNotifyTargetAsyncReturnsLiteralSaturationResponse() {
        let bus = TerminalMutationBus.shared
        resetBackpressureQueueState(bus)
        bus.setDrainsSuspendedForTesting(true)
        defer {
            resetBackpressureQueueState(bus)
        }

        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: UUID(),
                surfaceId: nil,
                title: "Seed \(index)",
                subtitle: "",
                body: ""
            ))
        }

        let response = TerminalController.debugNotifyTargetQueuedResponseForTesting(
            "\(UUID().uuidString) \(UUID().uuidString) Saturated|Retry|Body"
        )

        XCTAssertEqual(
            response,
            ReliableTerminalNotificationEnqueueResult.saturatedSocketResponse
        )
    }

    private func resetBackpressureQueueState(_ bus: TerminalMutationBus) {
        bus.lock.lock()
        bus.pending.removeAll(keepingCapacity: false)
        bus.pendingHead = 0
        bus.reliableAdmissionsById.removeAll(keepingCapacity: false)
        bus.notificationReplacementRoutesByTabId.removeAll()
        bus.notificationReplacementRouteOrder.removeAll()
        bus.notificationLiveOwnerTabIdBySurfaceId.removeAll()
        bus.notificationLiveOwnerSurfaceOrder.removeAll()
        bus.lock.broadcast()
        bus.lock.unlock()
        bus.drainForTesting()
        bus.setDrainsSuspendedForTesting(false)
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
        store.replaceNotificationsForTesting(Array(store.notifications) + [duringRelease])
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

    func testReleaseRestoredAwayWorkspacePreservesTransferredNotificationsAndQueuedWork() {
        let store = TerminalNotificationStore.shared
        let bus = TerminalMutationBus.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        let oldWorkspace = manager.addWorkspace(select: true)
        let newWorkspace = manager.addWorkspace(select: true)
        let oldPanelId = oldWorkspace.focusedPanelId!
        let newPanelId = newWorkspace.focusedPanelId!
        let notificationId = UUID()
        defer {
            bus.discardPendingNotifications()
            bus.drainForTesting()
            bus.setDrainsSuspendedForTesting(false)
            store.replaceNotificationsForTesting([])
            for workspace in manager.tabs {
                workspace.teardownAllPanels()
            }
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        store.replaceNotificationsForTesting([
            notification(
                id: notificationId,
                tabId: oldWorkspace.id,
                surfaceId: oldPanelId,
                title: "Transferred history",
                createdAt: Date(timeIntervalSince1970: 1),
                isRead: false
            ),
        ])
        XCTAssertTrue(bus.enqueueNotification(
            tabId: oldWorkspace.id,
            surfaceId: oldPanelId,
            title: "Queued during restore",
            subtitle: "",
            body: ""
        ))

        manager.releaseRestoredAwayWorkspaces(
            [oldWorkspace],
            originalWorkspaceIds: [oldWorkspace.id],
            replacements: [newWorkspace],
            panelIdMaps: [[oldPanelId: newPanelId]]
        )

        XCTAssertEqual(store.notifications.map(\.id), [notificationId])
        XCTAssertEqual(store.notifications.first?.tabId, newWorkspace.id)
        XCTAssertEqual(store.notifications.first?.surfaceId, newPanelId)
        let queued = bus.notificationIdentityStateForTesting()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.2, newWorkspace.id)
        XCTAssertEqual(queued.first?.3, newPanelId)
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
