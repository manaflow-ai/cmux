import Foundation
import Testing
import CmuxSettings
import CmuxWorkspaces

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
            settings: settings,
            panelTitleUpdateScheduler: scheduler
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
            settings: settings,
            panelTitleUpdateScheduler: scheduler
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

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: originalSurface,
            userInfo: staleUserInfo
        )

        await drainMainQueue()
        #expect(scheduler.delays.isEmpty)
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

    private final class ManualCoalescerScheduler: TitleFlushDelayScheduling {
        private struct PendingFlush {
            var isCancelled = false
            let action: @MainActor () -> Void
        }

        private var pendingFlushes: [PendingFlush] = []
        private(set) var delays: [TimeInterval] = []

        @MainActor
        func signal(_ action: @escaping () -> Void) {
            signal(delay: PanelTitleUpdateCoalescingSettings.defaultDelay, action)
        }

        @MainActor
        func signal(delay: TimeInterval, _ action: @escaping () -> Void) {
            _ = schedule(delay: delay, action: action)
        }

        @MainActor
        func schedule(
            delay: TimeInterval,
            action: @escaping @MainActor () -> Void
        ) -> PanelTitleUpdateCoalescer.Cancellation {
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
