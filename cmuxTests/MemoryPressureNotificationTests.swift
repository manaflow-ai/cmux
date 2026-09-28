import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentNotificationRegressionTests {
    @Test("Internal memory pressure never enters the user notification pipeline")
    func memoryPressureDoesNotDeliverNotifications() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let store = fixture.store
        let monitor = MemoryPressureMonitor.shared
        let originalResponders = monitor.registry.respondersByID
        let originalAggregatePressureCleared = monitor.onAggregatePressureCleared
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
