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
struct TabManagerTitleUpdateTests {
    @Test
    func coalescerReschedulesWhenDelayChangesMidBurst() async {
        let scheduler = ManualCoalescerScheduler()
        let coalescer = NotificationBurstCoalescer(
            delay: 0.02,
            schedule: scheduler.schedule(delay:action:)
        )
        var flushCount = 0

        coalescer.signal {
            flushCount += 1
        }
        #expect(scheduler.delays == [0.02])

        coalescer.signal(delay: 0.25) {
            flushCount += 1
        }
        #expect(scheduler.delays == [0.02, 0.25])

        scheduler.fire(at: 0)
        #expect(flushCount == 0)

        scheduler.fire(at: 1)
        #expect(flushCount == 1)
    }

    @Test
    func titleCoalescingDelayUsesCurrentSettingsAtNotificationTime() async throws {
        let suiteName = "TabManagerTitleCoalescingSettings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        let scheduler = ManualCoalescerScheduler()
        let manager = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        let workspace = try #require(manager.selectedWorkspace)
        let focusedPanelId = try #require(workspace.focusedPanelId)
        var notifiedWorkspaceIds: [UUID] = []
        let titleDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .workspaceTitleDidChange,
            object: manager,
            queue: nil
        ) { notification in
            if let workspaceId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID {
                notifiedWorkspaceIds.append(workspaceId)
            }
        }
        defer { NotificationCenter.default.removeObserver(titleDidChangeObserver) }

        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(300, for: catalog.terminal.titleUpdateCoalescingMilliseconds)

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: focusedPanelId,
                GhosttyNotificationKey.title: "Runtime Delay - grok"
            ]
        )

        await drainMainQueue()
        #expect(scheduler.delays == [0.3])
        #expect(workspace.panelTitles[focusedPanelId] != "Runtime Delay - grok")
        #expect(workspace.title != "Runtime Delay - grok")
        #expect(notifiedWorkspaceIds.isEmpty)

        scheduler.fire(at: 0)
        #expect(workspace.panelTitles[focusedPanelId] == "Runtime Delay - grok")
        #expect(workspace.title == "Runtime Delay - grok")
        #expect(notifiedWorkspaceIds == [workspace.id])
    }

    @Test
    func titleNotificationIgnoredWhenWorkspaceIsNotOwnedByManager() async throws {
        let suiteName = "TabManagerTitleOwnership.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(100, for: catalog.terminal.titleUpdateCoalescingMilliseconds)

        let scheduler = ManualCoalescerScheduler()
        let manager = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        let workspace = try #require(manager.selectedWorkspace)
        let focusedPanelId = try #require(workspace.focusedPanelId)
        let originalPanelTitle = workspace.panelTitles[focusedPanelId]

        #expect(workspace.owningTabManager === manager)
        workspace.owningTabManager = nil
        defer { workspace.owningTabManager = manager }

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: focusedPanelId,
                GhosttyNotificationKey.title: "Ignored Non Owner - grok"
            ]
        )

        await drainMainQueue()
        #expect(scheduler.delays.isEmpty)
        #expect(workspace.panelTitles[focusedPanelId] == originalPanelTitle)
        #expect(workspace.panelTitles[focusedPanelId] != "Ignored Non Owner - grok")
        #expect(workspace.title != "Ignored Non Owner - grok")
    }

    @Test
    func titleNotificationIgnoredAfterDirectWorkspaceModelRemoval() async throws {
        let suiteName = "TabManagerTitleDirectModelRemoval.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(100, for: catalog.terminal.titleUpdateCoalescingMilliseconds)

        let scheduler = ManualCoalescerScheduler()
        let manager = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        let workspace = try #require(manager.selectedWorkspace)
        let focusedPanelId = try #require(workspace.focusedPanelId)
        let originalPanelTitle = workspace.panelTitles[focusedPanelId]

        manager.workspaces.tabs = []

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: focusedPanelId,
                GhosttyNotificationKey.title: "Removed Workspace - grok"
            ]
        )

        await drainMainQueue()
        #expect(manager.tabs.isEmpty)
        #expect(scheduler.delays.isEmpty)
        #expect(workspace.panelTitles[focusedPanelId] == originalPanelTitle)
        #expect(workspace.panelTitles[focusedPanelId] != "Removed Workspace - grok")
    }

    @Test
    func pendingTitleUpdateIgnoredAfterPanelRemoval() async throws {
        let suiteName = "TabManagerTitleRemovedPanel.\(UUID().uuidString)"
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
        let removedPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let remainingPanel = try #require(workspace.newTerminalSurface(inPane: paneId, focus: true))
        let remainingTitle = try #require(workspace.panelTitles[remainingPanel.id])

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: removedPanelId,
                GhosttyNotificationKey.title: "Closed Panel - grok"
            ]
        )

        await drainMainQueue()
        #expect(scheduler.delays == [0.5])
        #expect(workspace.closePanel(removedPanelId, force: true))
        #expect(workspace.panels[removedPanelId] == nil)
        #expect(workspace.panels[remainingPanel.id] != nil)
        #expect(workspace.panelTitles[removedPanelId] == nil)
        let workspaceTitleAfterClose = workspace.title

        scheduler.fire(at: 0)

        #expect(workspace.panelTitles[removedPanelId] == nil)
        #expect(workspace.panelTitles[remainingPanel.id] == remainingTitle)
        #expect(workspace.title == workspaceTitleAfterClose)
        #expect(workspace.title != "Closed Panel - grok")
    }

    @Test
    func pendingTitleUpdateFlushesBeforeWorkspaceTransfer() async throws {
        let suiteName = "TabManagerTitleTransfer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(500, for: catalog.terminal.titleUpdateCoalescingMilliseconds)

        let scheduler = ManualCoalescerScheduler()
        let source = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                schedule: scheduler.schedule(delay:action:)
            ),
            settings: settings
        )
        let destination = TabManager(settings: settings)
        let workspace = try #require(source.selectedWorkspace)
        let focusedPanelId = try #require(workspace.focusedPanelId)
        let transferredTitle = "Moved Workspace - grok"

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: focusedPanelId,
                GhosttyNotificationKey.title: transferredTitle
            ]
        )

        await drainMainQueue()
        #expect(scheduler.delays == [0.5])
        #expect(workspace.panelTitles[focusedPanelId] != transferredTitle)
        #expect(workspace.title != transferredTitle)

        let detached = try #require(source.detachWorkspace(tabId: workspace.id))
        #expect(detached === workspace)
        #expect(workspace.panelTitles[focusedPanelId] == transferredTitle)
        #expect(workspace.title == transferredTitle)

        destination.attachWorkspace(detached, select: true)
        #expect(workspace.owningTabManager === destination)

        scheduler.fire(at: 0)
        #expect(workspace.panelTitles[focusedPanelId] == transferredTitle)
        #expect(workspace.title == transferredTitle)
    }

    @Test
    func rawTitleRefreshGateKeepsDefaultBehaviorUntilCoalescingIsEnabled() throws {
        let suiteName = "TabManagerTitleRawRefreshGate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        let manager = TabManager(settings: settings)
        let workspace = try #require(manager.selectedWorkspace)

        settings.set(1_000, for: catalog.terminal.titleUpdateCoalescingMilliseconds)
        #expect(manager.shouldScheduleRawTitleRefresh(forWorkspaceId: workspace.id))
        #expect(!manager.shouldScheduleRawTitleRefresh(forWorkspaceId: UUID()))

        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        #expect(!manager.shouldScheduleRawTitleRefresh(forWorkspaceId: workspace.id))

        settings.set(false, for: catalog.terminal.titleUpdateCoalescingEnabled)
        #expect(manager.shouldScheduleRawTitleRefresh(forWorkspaceId: workspace.id))
    }

    @Test
    func titleCoalescingDelayIsDefaultOffAndClampedWhenEnabled() throws {
        let suiteName = "TabManagerTitleCoalescingClamp.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()

        settings.set(1_000, for: catalog.terminal.titleUpdateCoalescingMilliseconds)
        #expect(
            abs(
                PanelTitleUpdateCoalescingSettings.delay(settings: settings) -
                    PanelTitleUpdateCoalescingSettings.defaultDelay
            ) < 0.000_1
        )

        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(1, for: catalog.terminal.titleUpdateCoalescingMilliseconds)
        #expect(abs(PanelTitleUpdateCoalescingSettings.delay(settings: settings) - 0.033) < 0.000_1)

        settings.set(10_000, for: catalog.terminal.titleUpdateCoalescingMilliseconds)
        #expect(abs(PanelTitleUpdateCoalescingSettings.delay(settings: settings) - 5.0) < 0.000_1)
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
