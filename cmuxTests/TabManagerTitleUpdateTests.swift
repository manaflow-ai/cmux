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

        func fire(at index: Int) {
            guard pendingFlushes.indices.contains(index), !pendingFlushes[index].isCancelled else { return }
            pendingFlushes[index].action()
        }
    }
}
