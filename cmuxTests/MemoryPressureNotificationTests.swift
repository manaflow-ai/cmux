import CmuxSettings
import Foundation
import Testing
import CmuxMemoryPressure

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace notification previews", .serialized, .exclusiveAppContext)
struct WorkspaceNotificationPreviewTests {
    @Test("Restored read workspace notices keep history without a card subtitle")
    func restoredReadWorkspaceNoticeHasNoSidebarPreview() throws {
        let fixture = try AgentNotificationRegressionTests().makeFixture()
        defer { fixture.restore() }
        let store = fixture.store
        // An older version persisted the localized notice without a surface.
        let legacy = SessionNotificationSnapshot(
            id: UUID(),
            title: "cmux 正处于严重内存压力下",
            subtitle: "已释放隐藏的渲染器和浏览器",
            body: "macOS 报告持续严重的内存压力。",
            createdAt: 1_789_138_582,
            isRead: true
        )
        let decoded = try JSONDecoder().decode(
            SessionNotificationSnapshot.self,
            from: JSONEncoder().encode(legacy)
        )
        let notification = decoded.terminalNotification(
            tabId: fixture.source.id, surfaceId: nil, panelId: nil
        )
        store.restoreSessionNotifications([notification], forTabId: fixture.source.id)

        let summary = store.sidebarUnread.snapshot.summary(forWorkspaceId: fixture.source.id)
        #expect(summary.unreadCount == 0)
        #expect(summary.latestNotificationText == nil)
        // Read history stays available to the notifications UI and its clear action.
        #expect(summary.hasLatestNotification)
        #expect(store.notifications(forTabIds: [fixture.source.id]).map(\.id) == [legacy.id])
        store.clearLatestNotification(forTabId: fixture.source.id)
        #expect(store.notification(id: legacy.id) == nil)
    }

    @Test("Reading a workspace notice clears its card subtitle", arguments: ["visit", "workspace", "notification"])
    func readingWorkspaceNoticeClearsSidebarPreview(path: String) throws {
        let fixture = try AgentNotificationRegressionTests().makeFixture()
        defer { fixture.restore() }
        let store = fixture.store
        let notification = TerminalNotification(
            id: UUID(), tabId: fixture.source.id, surfaceId: nil,
            title: "Workspace notice", subtitle: "", body: "Notice details",
            createdAt: Date(), isRead: false
        )
        store.replaceNotificationsForTesting([notification])
        #expect(store.sidebarUnread.snapshot.latestNotificationText(forWorkspaceId: fixture.source.id) == notification.body)

        switch path {
        case "visit": store.markWorkspaceLevelNotificationsRead(forTabId: fixture.source.id)
        case "workspace": store.markRead(forTabId: fixture.source.id)
        default: store.markRead(id: notification.id)
        }

        #expect(store.sidebarUnread.snapshot.latestNotificationText(forWorkspaceId: fixture.source.id) == nil)
        #expect(store.notification(id: notification.id)?.isRead == true)
        #expect(store.notifications(forTabIds: [fixture.source.id]).map(\.id) == [notification.id])
    }

    @Test("Read pane previews remain visible and clearable", arguments: ["surface", "panel", "both"])
    func readPanePreviewRemainsClearable(scope: String) throws {
        let fixture = try AgentNotificationRegressionTests().makeFixture()
        defer { fixture.restore() }
        let store = fixture.store
        let notification = TerminalNotification(
            id: UUID(), tabId: fixture.source.id,
            surfaceId: scope == "panel" ? nil : fixture.panelId,
            panelId: scope == "surface" ? nil : fixture.panelId,
            title: "Pane notice", subtitle: "", body: "Pane details",
            createdAt: Date(), isRead: true
        )
        store.replaceNotificationsForTesting([notification])

        let summary = store.sidebarUnread.snapshot.summary(forWorkspaceId: fixture.source.id)
        #expect(summary.latestNotificationText == notification.body)
        #expect(summary.hasLatestNotification)
        store.clearLatestNotification(forTabId: fixture.source.id)
        #expect(store.sidebarUnread.snapshot.latestNotificationText(forWorkspaceId: fixture.source.id) == nil)
        #expect(store.notification(id: notification.id) == nil)
    }

    @Test("The card clear action dismisses an unread notice without a surface")
    func unreadWorkspacePreviewIsClearable() throws {
        let fixture = try AgentNotificationRegressionTests().makeFixture()
        defer { fixture.restore() }
        let store = fixture.store
        let notification = TerminalNotification(
            id: UUID(), tabId: fixture.source.id, surfaceId: nil,
            title: "Workspace notice", subtitle: "", body: "Notice details",
            createdAt: Date(), isRead: false
        )
        store.replaceNotificationsForTesting([notification])
        let summary = store.sidebarUnread.snapshot.summary(forWorkspaceId: fixture.source.id)
        #expect(summary.latestNotificationText == notification.body)
        #expect(summary.hasLatestNotification)

        store.clearLatestNotification(forTabId: fixture.source.id)

        #expect(store.sidebarUnread.snapshot.latestNotificationText(forWorkspaceId: fixture.source.id) == nil)
        #expect(store.notification(id: notification.id) == nil)
    }
}

extension AgentNotificationRegressionTests {
    @Test("Internal memory pressure never enters the user notification pipeline")
    func memoryPressureDoesNotDeliverNotifications() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let store = fixture.store
        let monitor = MemoryPressureMonitor.shared
        let originalResponders = monitor.registry.respondersByID
        let originalAggregatePressureCleared = monitor.onAggregatePressureCleared
        let originalSampleApplied = monitor.onSampleApplied
        let controller = AgentHibernationController.shared
        let originalEvaluation = controller.memoryPressureEvaluation
        let originalConfirmations = controller.confirmations
        let originalCooldowns = store.lastNotificationDateByCooldownKey
        let originalHookFailures = store.lastNotificationHookFailureDateByKey
        let reorderKey = SettingCatalog().app.reorderOnNotification.userDefaultsKey
        let originalReorder = UserDefaults.standard.object(forKey: reorderKey)
        controller.memoryPressureEvaluation = nil
        controller.confirmations = [:]
        store.lastNotificationDateByCooldownKey = [:]
        store.lastNotificationHookFailureDateByKey = [:]
        UserDefaults.standard.set(true, forKey: reorderKey)
        defer {
            monitor.stop()
            monitor.registry.respondersByID = originalResponders
            monitor.onAggregatePressureCleared = originalAggregatePressureCleared
            monitor.onSampleApplied = originalSampleApplied
            controller.memoryPressureEvaluation?.task.cancel()
            controller.memoryPressureEvaluation = originalEvaluation
            controller.confirmations = originalConfirmations
            store.lastNotificationDateByCooldownKey = originalCooldowns
            store.lastNotificationHookFailureDateByKey = originalHookFailures
            if let originalReorder {
                UserDefaults.standard.set(originalReorder, forKey: reorderKey)
            } else {
                UserDefaults.standard.removeObject(forKey: reorderKey)
            }
        }

        var deliveredTitles: [String] = []
        var suppressedTitles: [String] = []
        store.configureNotificationDeliveryHandlerForTesting { _, notification, effects in
            // This is the admission boundary for desktop, sound, and command effects.
            #expect(effects.desktop && effects.sound && effects.command)
            deliveredTitles.append(notification.title)
        }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, notification, _ in
            suppressedTitles.append(notification.title)
        }

        // Install the real production pressure wiring, then
        // cancel sampling before yielding. Only synthetic pressure is delivered.
        fixture.appDelegate.startMemoryPressureMonitorIfNeeded()
        monitor.stop()
        let originalOrder = fixture.manager.tabs.map(\.id)
        let start = Date.now

        for elapsed in [0.0, 1, 301, 602] {
            // The old store cooldown uses wall time. Age its existing reservation
            // instead of waiting five minutes or replacing notification delivery.
            if elapsed > 300 {
                store.lastNotificationDateByCooldownKey["memory-pressure-aggregate"] =
                    start.addingTimeInterval(-elapsed)
            }
            fixture.manager.selectedTabId = elapsed < 300 ? fixture.source.id : fixture.destination.id
            let sampledAt = start.addingTimeInterval(elapsed)
            let sample = MemoryPressureAggregateSample(
                source: .coalition,
                aggregateBytes: 5_000,
                physicalMemoryBytes: 8_000,
                availableMemoryBytes: nil,
                processCount: 6,
                missingProcessCount: 0,
                sampledAt: sampledAt
            )
            let aggregate = MemoryPressureAggregatePolicy.default.evaluate(sample: sample)
            #expect(aggregate.isActionable)
            let actions = monitor.registry.dispatch(
                MemoryPressureSnapshot(
                    severity: aggregate.severity,
                    physicalFootprintBytes: 100,
                    aggregateMemoryPressure: aggregate,
                    sampledAt: sampledAt
                ),
                signal: .aggregate
            )
            #expect(actions.map(\.responderID) == ["aggregate-idle-agent-hibernation"])
            #expect(store.notifications.isEmpty)
            #expect(store.notificationFeedHistory.notifications.isEmpty)
            #expect(deliveredTitles.isEmpty)
            #expect(suppressedTitles.isEmpty)
            #expect(fixture.manager.tabs.map(\.id) == originalOrder)
        }

        // Sustained critical pressure must still execute the real cache responder
        // and schedule the hibernation owner's guarded evaluation.
        store.lastNotificationDateByCooldownKey["ordinary-stale-cache-entry"] =
            start.addingTimeInterval(-7_200)
        for elapsed in [0.0, 1, 60, 301, 602] {
            if elapsed > 300 {
                store.lastNotificationDateByCooldownKey["memory-pressure-critical"] =
                    start.addingTimeInterval(-elapsed)
            }
            monitor.recordSystemPressure(.critical, at: start.addingTimeInterval(elapsed))
            #expect(monitor.currentSeverity == .critical)
            #expect(controller.memoryPressureEvaluation != nil)
            #expect(store.notifications.isEmpty)
            #expect(store.notificationFeedHistory.notifications.isEmpty)
            #expect(store.unreadNotificationCount == 0)
            #expect(deliveredTitles.isEmpty)
            #expect(suppressedTitles.isEmpty)
            #expect(fixture.manager.tabs.map(\.id) == originalOrder)
            for workspace in [fixture.source, fixture.destination] {
                #expect(!store.workspaceIsUnread(forTabId: workspace.id))
                #expect(!store.hasUnreadNotificationRequiringPaneFlash(forTabId: workspace.id, surfaceId: nil))
                #expect(!store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: nil))
            }
        }
        #expect(store.lastNotificationDateByCooldownKey["ordinary-stale-cache-entry"] == nil)

        // A user is still allowed to send the former diagnostic title. This
        // proves suppression is not a global text filter or a disabled store.
        let userTitle = "cmux is using substantial aggregate memory"
        store.addNotification(
            tabId: fixture.destination.id,
            surfaceId: nil,
            title: userTitle,
            subtitle: "User message",
            body: "Keep ordinary notifications working"
        )
        TerminalMutationBus.shared.enqueueNotification(
            tabId: fixture.source.id,
            surfaceId: fixture.panelId,
            title: "Agent finished",
            subtitle: "Agent message",
            body: "Task complete"
        )
        TerminalMutationBus.shared.drainForTesting()

        #expect(deliveredTitles == [userTitle, "Agent finished"])
        #expect(suppressedTitles.isEmpty)
        #expect(store.notifications.count == 2)
        #expect(store.notificationFeedHistory.notifications.count == 2)
        #expect(store.unreadNotificationCount == 2)
        #expect(store.hasUnreadNotificationRequiringPaneFlash(
            forTabId: fixture.source.id,
            surfaceId: fixture.panelId
        ))
    }

    @Test("Aggregate response still schedules hibernation and clears recovered confirmations")
    func aggregateMemoryPressureResponseRetainsSafetyLifecycle() throws {
        let controller = AgentHibernationController.shared
        let previousEvaluation = controller.memoryPressureEvaluation
        let previousConfirmations = controller.confirmations
        controller.memoryPressureEvaluation = nil
        controller.confirmations = [:]
        defer {
            controller.memoryPressureEvaluation?.task.cancel()
            controller.memoryPressureEvaluation = previousEvaluation
            controller.confirmations = previousConfirmations
        }
        var pressureIsActive = true
        let responder = AggregateMemoryPressureResponder(
            controller: controller,
            isAggregatePressureActive: { pressureIsActive }
        )
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let aggregate = MemoryPressureAggregatePolicy.default.evaluate(sample: .init(
            source: .coalition,
            aggregateBytes: 5_000,
            physicalMemoryBytes: 8_000,
            availableMemoryBytes: nil,
            processCount: 6,
            missingProcessCount: 0,
            sampledAt: sampledAt
        ))
        let snapshot = MemoryPressureSnapshot(
            severity: aggregate.severity,
            physicalFootprintBytes: 100,
            aggregateMemoryPressure: aggregate,
            sampledAt: sampledAt
        )

        #expect(responder.shedMemory(for: snapshot).detail == "aggregate-idle-agent-evaluation")
        let evaluationID = try #require(controller.memoryPressureEvaluation?.id)
        #expect(responder.shedMemory(for: snapshot).detail == "aggregate-idle-agent-evaluation-in-flight")
        #expect(controller.memoryPressureEvaluation?.id == evaluationID)

        let aggregateKey = AgentHibernationPanelKey(workspaceId: UUID(), panelId: UUID())
        let systemKey = AgentHibernationPanelKey(workspaceId: UUID(), panelId: UUID())
        for (key, trigger) in [(aggregateKey, AgentHibernationReclaimTrigger.aggregateMemoryPressure),
                               (systemKey, .systemMemoryPressure)] {
            controller.confirmations[key] = .init(
                trigger: trigger,
                fingerprint: "unchanged-output",
                processIdentities: [:],
                sampledAt: 1_000,
                dueAt: 1_005
            )
        }
        pressureIsActive = false
        _ = responder.shedMemory(for: snapshot)
        #expect(controller.confirmations[aggregateKey] == nil)
        #expect(controller.confirmations[systemKey] != nil)
    }
}
