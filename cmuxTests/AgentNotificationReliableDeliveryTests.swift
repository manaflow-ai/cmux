import Foundation
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AgentNotificationReliableDeliveryTests: XCTestCase {
    func testSerializesMultipleCallersOffMainActor() async {
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }
        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: UUID(), surfaceId: nil, title: "Seed \(index)", subtitle: "", body: ""
            ))
        }

        let deliveries = (0..<3).map { index in
            Task { @MainActor in
                await AgentNotificationDelivery().enqueueReliably(
                    workspaceID: UUID(), surfaceID: UUID(), title: "Reliable \(index)",
                    subtitle: "", body: "", category: nil, pending: false
                )
            }
        }
        await waitForReliableAdmissionBlock(bus)

        bus.drainForBackpressure()

        for delivery in deliveries {
            let result = await delivery.value
            XCTAssertEqual(result, .accepted)
        }
        let queuedTitles = bus.notificationQueueStateForTesting().1
        let reliableTitles = queuedTitles.filter { $0.hasPrefix("Reliable ") }
        XCTAssertEqual(reliableTitles.count, 3)
        XCTAssertEqual(Set(reliableTitles), ["Reliable 0", "Reliable 1", "Reliable 2"])
        let identities = bus.notificationIdentityStateForTesting()
        let reliableIdentities = queuedTitles.enumerated().compactMap { index, title in
            title.hasPrefix("Reliable ") ? identities[index] : nil
        }
        XCTAssertEqual(Set(reliableIdentities.map(\.0)).count, 3)
        XCTAssertEqual(reliableIdentities.map(\.1), reliableIdentities.map(\.1).sorted())
    }

    func testCannotCrossClearBoundary() async {
        let bus = TerminalMutationBus.shared
        let tabId = UUID()
        let surfaceId = UUID()
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }
        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: tabId, surfaceId: surfaceId, title: "Seed \(index)", subtitle: "", body: ""
            ))
        }
        let preClear = Task { @MainActor in
            await AgentNotificationDelivery().enqueueReliably(
                workspaceID: tabId, surfaceID: surfaceId, title: "Must not survive clear",
                subtitle: "", body: "", category: nil, pending: false
            )
        }
        await waitForReliableAdmissionBlock(bus)

        bus.enqueueClearNotifications(forTabId: tabId, surfaceId: surfaceId)

        let preClearResult = await preClear.value
        XCTAssertEqual(preClearResult, .cancelled)
        XCTAssertFalse(bus.notificationQueueStateForTesting().1.contains("Must not survive clear"))
        let postClearResult = await AgentNotificationDelivery().enqueueReliably(
            workspaceID: tabId, surfaceID: surfaceId, title: "Accepted after clear",
            subtitle: "", body: "", category: nil, pending: false
        )
        XCTAssertEqual(postClearResult, .accepted)
        XCTAssertEqual(bus.notificationQueueStateForTesting().1, ["Accepted after clear"])
    }

    func testSurfaceAddressedAdmissionCannotCrossWorkspaceClearBoundary() async {
        let bus = TerminalMutationBus.shared
        let tabId = UUID()
        let surfaceId = UUID()
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }
        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: tabId, surfaceId: surfaceId, title: "Seed \(index)", subtitle: "", body: ""
            ))
        }
        let preClear = Task { @MainActor in
            await AgentNotificationDelivery().enqueueReliably(
                workspaceID: tabId, surfaceID: surfaceId, title: "Must not resurrect after workspace clear",
                subtitle: "", body: "", category: nil, pending: false
            )
        }
        await waitForReliableAdmissionBlock(bus)

        bus.enqueueClearNotifications(forTabId: tabId)
        bus.drainForBackpressure()

        let preClearResult = await preClear.value
        XCTAssertEqual(preClearResult, .cancelled)
        XCTAssertFalse(bus.notificationQueueStateForTesting().1.contains("Must not resurrect after workspace clear"))
    }

    func testFallbackCapableAdmissionCannotResurrectAfterWorkspaceClear() async {
        let bus = TerminalMutationBus.shared
        let tabId = UUID()
        let disappearedSurfaceId = UUID()
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }
        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: UUID(), surfaceId: nil, title: "Seed \(index)", subtitle: "", body: ""
            ))
        }
        let preClear = Task { @MainActor in
            await AgentNotificationDelivery().enqueueReliably(
                workspaceID: tabId,
                surfaceID: disappearedSurfaceId,
                title: "Must not fallback after clear",
                subtitle: "",
                body: "",
                category: nil,
                pending: false,
                allowWorkspaceFallbackForValidatedSurface: true
            )
        }
        await waitForReliableAdmissionBlock(bus)

        bus.discardPendingNotificationsResolvingLiveOwner(forTabId: tabId)
        bus.drainForBackpressure()

        let preClearResult = await preClear.value
        XCTAssertEqual(preClearResult, .cancelled)
        XCTAssertFalse(bus.notificationQueueStateForTesting().1.contains("Must not fallback after clear"))
    }

    func testMigratesAcrossSessionTransfer() async {
        let bus = TerminalMutationBus.shared
        let oldTabId = UUID()
        let newTabId = UUID()
        let oldSurfaceId = UUID()
        let newSurfaceId = UUID()
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }
        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: oldTabId, surfaceId: oldSurfaceId, title: "Seed \(index)", subtitle: "", body: ""
            ))
        }
        let preTransfer = Task { @MainActor in
            await AgentNotificationDelivery().enqueueReliably(
                workspaceID: oldTabId, surfaceID: oldSurfaceId, title: "Must survive transfer once",
                subtitle: "", body: "", category: nil, pending: false
            )
        }
        await waitForReliableAdmissionBlock(bus)
        let transferTime = Date()

        bus.transferPendingNotifications(
            fromTabId: oldTabId, toTabId: newTabId, panelIdMap: [oldSurfaceId: newSurfaceId]
        )
        bus.drainForBackpressure()

        let preTransferResult = await preTransfer.value
        XCTAssertEqual(preTransferResult, .accepted)
        let titles = bus.notificationQueueStateForTesting().1
        XCTAssertEqual(titles.filter { $0 == "Must survive transfer once" }.count, 1)
        guard let reliableIndex = titles.firstIndex(of: "Must survive transfer once") else {
            return XCTFail("Transferred reliable notification was not admitted")
        }
        let identity = bus.notificationIdentityStateForTesting()[reliableIndex]
        XCTAssertEqual(identity.2, newTabId)
        XCTAssertEqual(identity.3, newSurfaceId)
        XCTAssertLessThanOrEqual(identity.1, transferTime)
    }

    func testUnmappedSurfaceSurvivesReliableAdmissionSessionTransfer() async {
        let bus = TerminalMutationBus.shared
        let oldTabId = UUID()
        let newTabId = UUID()
        let unmappedSurfaceId = UUID()
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }
        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: oldTabId, surfaceId: unmappedSurfaceId, title: "Seed \(index)", subtitle: "", body: ""
            ))
        }
        let preTransfer = Task { @MainActor in
            await AgentNotificationDelivery().enqueueReliably(
                workspaceID: oldTabId, surfaceID: unmappedSurfaceId, title: "Must retain unmapped surface",
                subtitle: "", body: "", category: nil, pending: false
            )
        }
        await waitForReliableAdmissionBlock(bus)

        bus.transferPendingNotifications(fromTabId: oldTabId, toTabId: newTabId, panelIdMap: [:])
        bus.drainForBackpressure()

        let result = await preTransfer.value
        XCTAssertEqual(result, .accepted)
        let titles = bus.notificationQueueStateForTesting().1
        guard let index = titles.firstIndex(of: "Must retain unmapped surface") else {
            return XCTFail("Transferred reliable notification was not admitted")
        }
        let identity = bus.notificationIdentityStateForTesting()[index]
        XCTAssertEqual(identity.2, newTabId)
        XCTAssertEqual(identity.3, unmappedSurfaceId)
    }

    func testReliableAdmissionStartedAfterSessionTransferUsesReplacementRoute() async {
        let bus = TerminalMutationBus.shared
        let oldTabId = UUID()
        let newTabId = UUID()
        let oldSurfaceId = UUID()
        let newSurfaceId = UUID()
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }

        bus.transferPendingNotifications(
            fromTabId: oldTabId,
            toTabId: newTabId,
            panelIdMap: [oldSurfaceId: newSurfaceId]
        )

        let result = await AgentNotificationDelivery().enqueueReliably(
            workspaceID: oldTabId,
            surfaceID: oldSurfaceId,
            title: "Accepted after replacement scan",
            subtitle: "",
            body: "",
            category: nil,
            pending: false
        )

        XCTAssertEqual(result, .accepted)
        let titles = bus.notificationQueueStateForTesting().1
        guard let index = titles.firstIndex(of: "Accepted after replacement scan") else {
            return XCTFail("Replacement-routed reliable notification was not admitted")
        }
        let identity = bus.notificationIdentityStateForTesting()[index]
        XCTAssertEqual(identity.2, newTabId)
        XCTAssertEqual(identity.3, newSurfaceId)
    }

    func testValidatedReliableAdmissionFallsBackToWorkspaceIfSurfaceDisappearsBeforeDrain() async throws {
        let bus = TerminalMutationBus.shared
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false
        let workspace = manager.addWorkspace(select: true)
        let surfaceId = UUID()
        defer {
            reset(bus)
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let result = await AgentNotificationDelivery().enqueueReliably(
            workspaceID: workspace.id,
            surfaceID: surfaceId,
            title: "Validated completion",
            subtitle: "",
            body: "",
            category: nil,
            pending: false,
            allowWorkspaceFallbackForValidatedSurface: true
        )
        XCTAssertEqual(result, .accepted)

        bus.drainForTesting()

        let recorded = Array(store.notifications)
        XCTAssertEqual(recorded.map(\.title), ["Validated completion"])
        XCTAssertEqual(recorded.first?.tabId, workspace.id)
        XCTAssertNil(recorded.first?.surfaceId)
        XCTAssertNil(recorded.first?.panelId)
    }

    func testValidatedPolicyRequestFallsBackToOpenableWorkspaceRow() {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        let workspace = manager.addWorkspace(select: true)
        let stalePanelId = UUID()
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        let request = TerminalNotificationPolicyRequest(
            tabId: workspace.id,
            surfaceId: stalePanelId,
            panelId: stalePanelId,
            retargetsToLiveSurfaceOwner: true,
            title: "Validated completion",
            subtitle: "",
            body: "",
            cwd: nil,
            isAppFocused: false,
            isFocusedPanel: false
        )

        let retargeted = store.notificationPolicyRequestAtLiveOwner(request)
        XCTAssertEqual(retargeted?.tabId, workspace.id)
        XCTAssertNil(retargeted?.surfaceId)
        XCTAssertNil(retargeted?.panelId)
    }

    func testClearStartedAfterSessionTransferUsesReplacementRoute() {
        let bus = TerminalMutationBus.shared
        let oldTabId = UUID()
        let newTabId = UUID()
        let oldSurfaceId = UUID()
        let newSurfaceId = UUID()
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }

        bus.transferPendingNotifications(
            fromTabId: oldTabId,
            toTabId: newTabId,
            panelIdMap: [oldSurfaceId: newSurfaceId]
        )
        XCTAssertTrue(bus.enqueueNotification(
            tabId: oldTabId,
            surfaceId: oldSurfaceId,
            title: "Must be cleared through replacement route",
            subtitle: "",
            body: ""
        ))

        bus.enqueueClearNotifications(forTabId: oldTabId, surfaceId: oldSurfaceId)

        XCTAssertFalse(
            bus.notificationQueueStateForTesting().1.contains("Must be cleared through replacement route")
        )
    }

    func testReliableAdmissionBacklogIsBounded() async {
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }
        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: UUID(), surfaceId: nil, title: "Seed \(index)", subtitle: "", body: ""
            ))
        }

        let deliveries = (0...TerminalMutationBus.maximumWaitingNotificationProducerCount).map { index in
            Task { @MainActor in
                await AgentNotificationDelivery().enqueueReliably(
                    workspaceID: UUID(), surfaceID: UUID(), title: "Bounded \(index)",
                    subtitle: "", body: "", category: nil, pending: false
                )
            }
        }
        await waitForReliableAdmissionBlock(bus)
        for _ in 0..<10_000 { await Task.yield() }

        XCTAssertEqual(bus.reliablyWaitingNotificationProducerCountForTesting(), 1)

        bus.drainForBackpressure()
        bus.drainForBackpressure()
        var results: [AgentNotificationDeliveryResult] = []
        for delivery in deliveries { results.append(await delivery.value) }
        XCTAssertEqual(results.filter { $0 == .accepted }.count, deliveries.count)
        XCTAssertEqual(results.filter { $0 == .saturated }.count, 0)
        XCTAssertEqual(results.filter { $0 == .cancelled }.count, 0)
    }

    func testReliableAdmissionTruncatesPayloadBeforeQueueing() async {
        let bus = TerminalMutationBus.shared
        let title = String(repeating: "é", count: TerminalNotificationStore.maximumNotificationTitleBytes)
        let subtitle = String(repeating: "s", count: TerminalNotificationStore.maximumNotificationSubtitleBytes + 128)
        let body = String(repeating: "b", count: TerminalNotificationStore.maximumNotificationBodyBytes + 128)
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }

        let result = await AgentNotificationDelivery().enqueueReliably(
            workspaceID: UUID(),
            surfaceID: UUID(),
            title: title,
            subtitle: subtitle,
            body: body,
            category: nil,
            pending: false
        )

        XCTAssertEqual(result, .accepted)
        let queuedTitles = bus.notificationQueueStateForTesting().1
        XCTAssertEqual(queuedTitles.count, 1)
        XCTAssertLessThanOrEqual(queuedTitles[0].utf8.count, TerminalNotificationStore.maximumNotificationTitleBytes)
    }

    func testReliableAdmissionContentByteBudgetRejectsBeforeRetainingBacklog() {
        let bus = TerminalMutationBus.shared
        let body = String(repeating: "b", count: TerminalNotificationStore.maximumNotificationBodyBytes)
        let byteLimitedCount = TerminalMutationBus.maximumQueuedNotificationContentBytes / body.utf8.count
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }

        for _ in 0..<byteLimitedCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: UUID(),
                surfaceId: nil,
                title: "",
                subtitle: "",
                body: body
            ))
        }

        let result = AgentNotificationDelivery().enqueueReliablySynchronously(
            workspaceID: UUID(),
            surfaceID: UUID(),
            title: "",
            subtitle: "",
            body: body,
            category: nil,
            pending: false
        )
        XCTAssertEqual(result, .saturated)
        XCTAssertEqual(bus.reliablyWaitingNotificationProducerCountForTesting(), 0)
    }

    func testReliableAdmissionDeadlineStartsAtCaptureForBackloggedSubmitters() async {
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }
        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: UUID(),
                surfaceId: nil,
                title: "Seed \(index)",
                subtitle: "",
                body: ""
            ))
        }

        let startedAt = Date()
        let deliveries = (0..<4).map { index in
            Task { @MainActor in
                await AgentNotificationDelivery().enqueueReliably(
                    workspaceID: UUID(),
                    surfaceID: UUID(),
                    title: "Deadline \(index)",
                    subtitle: "",
                    body: "",
                    category: nil,
                    pending: false
                )
            }
        }

        var results: [AgentNotificationDeliveryResult] = []
        for delivery in deliveries {
            results.append(await delivery.value)
        }

        XCTAssertEqual(results, Array(repeating: .saturated, count: deliveries.count))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), TerminalMutationBus.notificationCapacityWaitTimeout + 1.5)
        XCTAssertEqual(bus.reliablyWaitingNotificationProducerCountForTesting(), 0)
        XCTAssertFalse(bus.notificationQueueStateForTesting().1.contains { $0.hasPrefix("Deadline ") })
    }

    func testLiveOwnerRoutesAreBoundedAndRemovable() {
        let bus = TerminalMutationBus.shared
        let staleTabId = UUID()
        let firstSurfaceId = UUID()
        let firstOwnerTabId = UUID()
        var installedSurfaceIds = [firstSurfaceId]
        defer {
            for surfaceId in installedSurfaceIds {
                bus.removeNotificationLiveOwnerRoute(surfaceId: surfaceId)
            }
        }

        bus.rebindPendingNotifications(
            fromTabId: staleTabId,
            toTabId: firstOwnerTabId,
            surfaceId: firstSurfaceId
        )
        XCTAssertEqual(
            bus.routedNotificationKey(tabId: staleTabId, surfaceId: firstSurfaceId).tabId,
            firstOwnerTabId
        )

        let maxRoutes = TerminalMutationBus.maximumNotificationLiveOwnerRouteCount
        let newestSurfaceIds = (0..<maxRoutes).map { _ in UUID() }
        let newestOwnerTabIds = newestSurfaceIds.map { _ in UUID() }
        installedSurfaceIds.append(contentsOf: newestSurfaceIds)
        for (surfaceId, ownerTabId) in zip(newestSurfaceIds, newestOwnerTabIds) {
            bus.rebindPendingNotifications(
                fromTabId: staleTabId,
                toTabId: ownerTabId,
                surfaceId: surfaceId
            )
        }

        XCTAssertEqual(
            bus.routedNotificationKey(tabId: staleTabId, surfaceId: firstSurfaceId).tabId,
            staleTabId
        )
        let newestSurfaceId = newestSurfaceIds[maxRoutes - 1]
        let newestOwnerTabId = newestOwnerTabIds[maxRoutes - 1]
        XCTAssertEqual(
            bus.routedNotificationKey(tabId: staleTabId, surfaceId: newestSurfaceId).tabId,
            newestOwnerTabId
        )

        bus.removeNotificationLiveOwnerRoute(surfaceId: newestSurfaceId)
        XCTAssertEqual(
            bus.routedNotificationKey(tabId: staleTabId, surfaceId: newestSurfaceId).tabId,
            staleTabId
        )
    }

    func testLiveOwnerRouteContinuesThroughLaterSessionReplacementRoute() {
        let bus = TerminalMutationBus.shared
        let staleTabId = UUID()
        let liveOwnerTabId = UUID()
        let restoredTabId = UUID()
        let oldSurfaceId = UUID()
        let restoredSurfaceId = UUID()
        defer {
            bus.removeNotificationLiveOwnerRoute(surfaceId: oldSurfaceId)
            bus.removeNotificationLiveOwnerRoute(surfaceId: restoredSurfaceId)
        }

        bus.rebindPendingNotifications(
            fromTabId: staleTabId,
            toTabId: liveOwnerTabId,
            surfaceId: oldSurfaceId
        )
        bus.transferPendingNotifications(
            fromTabId: liveOwnerTabId,
            toTabId: restoredTabId,
            panelIdMap: [oldSurfaceId: restoredSurfaceId]
        )

        let routed = bus.routedNotificationKey(tabId: staleTabId, surfaceId: oldSurfaceId)
        XCTAssertEqual(routed.tabId, restoredTabId)
        XCTAssertEqual(routed.surfaceId, restoredSurfaceId)
    }

    private func waitForReliableAdmissionBlock(_ bus: TerminalMutationBus) async {
        let deadline = Date(timeIntervalSinceNow: 2)
        while Date() < deadline {
            if bus.reliablyWaitingNotificationProducerCountForTesting() == 1 { return }
            await Task.yield()
        }
        XCTFail("Reliable admission worker did not reach the capacity wait")
    }

    private func reset(_ bus: TerminalMutationBus) {
        bus.discardPendingNotifications()
        bus.drainForTesting()
        bus.setDrainsSuspendedForTesting(false)
    }
}
