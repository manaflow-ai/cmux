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
        let coalescer = NotificationBurstCoalescer(delay: 0.02)
        var flushCount = 0

        coalescer.signal {
            flushCount += 1
        }
        try? await Task.sleep(nanoseconds: nanoseconds(for: 0.005))
        coalescer.signal(delay: 0.25) {
            flushCount += 1
        }

        try? await Task.sleep(nanoseconds: nanoseconds(for: 0.10))
        #expect(flushCount == 0)
        #expect(await waitForTitleCondition(timeout: 1.0) { flushCount == 1 })
    }

    @Test
    func titleCoalescingDelayUsesCurrentSettingsAtNotificationTime() async throws {
        let suiteName = "TabManagerTitleCoalescingSettings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        let manager = TabManager(settings: settings)
        let workspace = try #require(manager.selectedWorkspace)
        let focusedPanelId = try #require(workspace.focusedPanelId)

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

        try? await Task.sleep(nanoseconds: nanoseconds(for: 0.12))
        #expect(workspace.panelTitles[focusedPanelId] != "Runtime Delay - grok")
        #expect(workspace.title != "Runtime Delay - grok")

        #expect(
            await waitForTitleCondition(timeout: 1.0) {
                workspace.panelTitles[focusedPanelId] == "Runtime Delay - grok" &&
                    workspace.title == "Runtime Delay - grok"
            }
        )
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

        let manager = TabManager(settings: settings)
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

        try? await Task.sleep(nanoseconds: nanoseconds(for: 0.25))
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

    private func waitForTitleCondition(
        timeout: TimeInterval = 3.0,
        pollInterval: TimeInterval = 0.05,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        if condition() {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: nanoseconds(for: pollInterval))
        }
        return condition()
    }

    private func nanoseconds(for delay: TimeInterval) -> UInt64 {
        let nanoseconds = delay * 1_000_000_000
        guard nanoseconds.isFinite, nanoseconds > 0 else { return 0 }
        return UInt64(min(nanoseconds.rounded(.up), Double(UInt64.max)))
    }
}
