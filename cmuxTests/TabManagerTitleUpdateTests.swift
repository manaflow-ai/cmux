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
        let sleeper = ManualCoalescerSleep()
        let coalescer = NotificationBurstCoalescer(
            delay: 0.02,
            sleep: { try await sleeper.sleep(nanoseconds: $0) }
        )
        var flushCount = 0

        coalescer.signal {
            flushCount += 1
        }
        #expect(await yieldUntil { await sleeper.pendingCount() == 1 })

        coalescer.signal(delay: 0.25) {
            flushCount += 1
        }
        #expect(await yieldUntil { await sleeper.pendingCount() == 2 })
        #expect(await sleeper.requestedNanoseconds() == [20_000_000, 250_000_000])

        await sleeper.releaseNext()
        await Task.yield()
        #expect(flushCount == 0)

        await sleeper.releaseNext()
        #expect(await yieldUntil { flushCount == 1 })
    }

    @Test
    func titleCoalescingDelayUsesCurrentSettingsAtNotificationTime() async throws {
        let suiteName = "TabManagerTitleCoalescingSettings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        let sleeper = ManualCoalescerSleep()
        let manager = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                sleep: { try await sleeper.sleep(nanoseconds: $0) }
            ),
            settings: settings
        )
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

        #expect(await yieldUntil { await sleeper.pendingCount() == 1 })
        #expect(await sleeper.requestedNanoseconds() == [300_000_000])
        #expect(workspace.panelTitles[focusedPanelId] != "Runtime Delay - grok")
        #expect(workspace.title != "Runtime Delay - grok")

        await sleeper.releaseNext()
        #expect(await yieldUntil {
            workspace.panelTitles[focusedPanelId] == "Runtime Delay - grok" &&
                workspace.title == "Runtime Delay - grok"
        })
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

        let sleeper = ManualCoalescerSleep()
        let manager = TabManager(
            panelTitleUpdateCoalescer: NotificationBurstCoalescer(
                sleep: { try await sleeper.sleep(nanoseconds: $0) }
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

        await yieldMainActor()
        #expect(await sleeper.pendingCount() == 0)
        #expect(await sleeper.requestedNanoseconds().isEmpty)
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

    private func yieldUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return await condition()
    }

    private func yieldMainActor() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    private actor ManualCoalescerSleep {
        private var pendingContinuations: [CheckedContinuation<Void, Never>] = []
        private var requested: [UInt64] = []

        func sleep(nanoseconds: UInt64) async throws {
            requested.append(nanoseconds)
            await withCheckedContinuation { continuation in
                pendingContinuations.append(continuation)
            }
        }

        func pendingCount() -> Int {
            pendingContinuations.count
        }

        func requestedNanoseconds() -> [UInt64] {
            requested
        }

        func releaseNext() {
            guard !pendingContinuations.isEmpty else { return }
            let continuation = pendingContinuations.removeFirst()
            continuation.resume()
        }
    }
}
