import Foundation
import Testing
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TabManagerTitleUpdateStalenessTests {
    @Test
    func pendingTitleUpdateIgnoredAfterTerminalRespawnReusesPanelId() async throws {
        let suiteName = "TabManagerTitleRespawnReuse.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(500, for: catalog.terminal.titleUpdateCoalescingMilliseconds)

        let scheduler = ManualCoalescerScheduler()
        let manager = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let originalPanel = try #require(workspace.terminalPanel(for: panelId))
        let originalSurface = originalPanel.surface
        let staleTitle = "Stale Respawn Title - grok"

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: originalSurface,
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: panelId,
                GhosttyNotificationKey.title: staleTitle
            ]
        )

        await drainMainQueue()
        #expect(scheduler.delays == [0.5])
        #expect(workspace.panelTitles[panelId] != staleTitle)

        let replacementPanel = try #require(
            workspace.respawnTerminalSurface(panelId: panelId, command: "echo replacement")
        )
        #expect(replacementPanel.id == panelId)
        #expect(replacementPanel.surface !== originalSurface)
        #expect(workspace.panelTitles[panelId] != staleTitle)

        scheduler.fire(at: 0)

        #expect(workspace.terminalPanel(for: panelId)?.surface === replacementPanel.surface)
        #expect(workspace.panelTitles[panelId] != staleTitle)
        #expect(workspace.title != staleTitle)
    }

    @Test
    func pendingTitleUpdateIgnoredAfterHibernationRetainsTerminalSurface() async throws {
        let suiteName = "TabManagerTitleHibernation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(500, for: catalog.terminal.titleUpdateCoalescingMilliseconds)

        let scheduler = ManualCoalescerScheduler()
        let manager = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let terminal = try #require(workspace.terminalPanel(for: panelId))
        let retainedSurface = terminal.surface
        let originalLifecycleID = retainedSurface.terminalLifecycleId
        let staleTitle = "Stale Hibernated Title - grok"

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: retainedSurface,
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: panelId,
                GhosttyNotificationKey.title: staleTitle,
            ]
        )

        await drainMainQueue()
        #expect(scheduler.delays == [0.5])
        #expect(workspace.panelTitles[panelId] != staleTitle)

        #expect(retainedSurface.suspendRuntimeSurfaceForAgentHibernation(
            reason: "test.pendingWorkspaceTitle"
        ))
        #expect(terminal.surface === retainedSurface)
        #expect(retainedSurface.terminalLifecycleId != originalLifecycleID)

        scheduler.fire(at: 0)

        #expect(workspace.terminalPanel(for: panelId)?.surface === retainedSurface)
        #expect(workspace.panelTitles[panelId] != staleTitle)
        #expect(workspace.title != staleTitle)
    }

    @Test
    func delayedGhosttyTitleIgnoredAfterSourceLifecycleAdvances() async throws {
        let suiteName = "TabManagerTitleDispatcherHibernation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(500, for: catalog.terminal.titleUpdateCoalescingMilliseconds)

        let panelScheduler = ManualCoalescerScheduler()
        let manager = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: panelScheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let terminal = try #require(workspace.terminalPanel(for: panelId))
        let retainedSurface = terminal.surface
        let callbackLifecycleID = retainedSurface.terminalLifecycleId
        let staleTitle = "Delayed Retired Runtime Title - codex"
        let center = NotificationCenter.default
        let titleScheduler = TitleScheduleRecorder()
        let ingress = GhosttyTitleUpdateIngress(
            center: center,
            schedule: { interval, action in
                titleScheduler.schedule(interval, action: action)
            }
        )

        #expect(ingress.submit(
            tabId: workspace.id,
            surfaceId: panelId,
            sourceSurfaceIdentifier: ObjectIdentifier(retainedSurface),
            terminalLifecycleID: callbackLifecycleID,
            title: staleTitle
        ))
        await titleScheduler.awaitFirstSchedule()

        #expect(retainedSurface.suspendRuntimeSurfaceForAgentHibernation(
            reason: "test.delayedGhosttyTitle"
        ))
        #expect(retainedSurface.terminalLifecycleId != callbackLifecycleID)

        await titleScheduler.fire()

        #expect(panelScheduler.delays.isEmpty)
        #expect(workspace.panelTitles[panelId] != staleTitle)
        #expect(workspace.title != staleTitle)
    }

    @Test
    func delayedTypedTitleChangePreservesSourceLifecycle() {
        let terminalLifecycleID = UUID()
        let change = GhosttyTitleChange(
            tabId: UUID(),
            surfaceId: UUID(),
            title: "Lifecycle payload",
            sourceSurfaceIdentifier: ObjectIdentifier(NSObject()),
            terminalLifecycleID: terminalLifecycleID
        )

        let notification = Notification(
            name: .ghosttyDidSetTitle,
            userInfo: change.userInfo
        )

        #expect(
            GhosttyTitleChange(notification: notification)?.terminalLifecycleID
                == terminalLifecycleID
        )
    }

    @Test
    func queuedTitleNotificationIgnoredAfterTerminalRespawnReusesPanelId() async throws {
        let suiteName = "TabManagerTitleQueuedRespawnReuse.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(500, for: catalog.terminal.titleUpdateCoalescingMilliseconds)

        let scheduler = ManualCoalescerScheduler()
        let manager = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let originalSurface = try #require(workspace.terminalPanel(for: panelId)?.surface)
        let staleTitle = "Queued Stale Respawn Title - grok"
        let staleUserInfo: [String: Any] = [
            GhosttyNotificationKey.tabId: workspace.id,
            GhosttyNotificationKey.surfaceId: panelId,
            GhosttyNotificationKey.title: staleTitle,
        ]

        let replacementPanel = try #require(
            workspace.respawnTerminalSurface(panelId: panelId, command: "echo replacement")
        )
        #expect(replacementPanel.id == panelId)
        #expect(replacementPanel.surface !== originalSurface)

        let staleSourceSurfaces: [AnyObject?] = [originalSurface, nil]
        for staleSourceSurface in staleSourceSurfaces {
            NotificationCenter.default.post(
                name: .ghosttyDidSetTitle,
                object: staleSourceSurface,
                userInfo: staleUserInfo
            )

            await drainMainQueue()
            #expect(scheduler.delays.isEmpty)
        }
        #expect(workspace.terminalPanel(for: panelId)?.surface === replacementPanel.surface)
        #expect(workspace.panelTitles[panelId] != staleTitle)
        #expect(workspace.title != staleTitle)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private final class ManualCoalescerScheduler {
        private struct PendingFlush {
            var isCancelled = false
            let action: @MainActor () -> Void
        }

        private var pendingFlushes: [PendingFlush] = []
        private(set) var delays: [TimeInterval] = []

        @MainActor
        func schedule(
            delay: TimeInterval,
            action: @escaping @MainActor () -> Void
        ) -> NotificationBurstCoalescer.Cancellation {
            let index = pendingFlushes.count
            delays.append(delay)
            pendingFlushes.append(PendingFlush(action: action))
            return { [weak self] in
                self?.pendingFlushes[index].isCancelled = true
            }
        }

        @MainActor
        func fire(at index: Int) {
            guard pendingFlushes.indices.contains(index), !pendingFlushes[index].isCancelled else { return }
            pendingFlushes[index].action()
        }
    }
}
