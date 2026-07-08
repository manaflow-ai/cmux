import Foundation
import Testing
import CmuxSettings
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct AppDelegateMoveTabToNewWorkspaceTests {
    @Test
    func moveSurfaceToNewWorkspaceCreatesSinglePanelWorkspaceFromPanelTitle() throws {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let sourceWorkspace = try #require(manager.selectedWorkspace)
        let sourcePaneId = try #require(sourceWorkspace.bonsplitController.allPaneIds.first)
        let remainingPanelId = try #require(sourceWorkspace.focusedTerminalPanel?.id)
        let movedPanel = try #require(sourceWorkspace.newTerminalSurface(inPane: sourcePaneId, focus: false))
        sourceWorkspace.setPanelCustomTitle(panelId: movedPanel.id, title: "Build logs")

        let originalWorkspaceCount = manager.tabs.count
        let result = try #require(app.moveSurfaceToNewWorkspace(
            panelId: movedPanel.id,
            focus: false,
            focusWindow: false
        ))

        let destinationWorkspace = try #require(manager.tabs.first { $0.id == result.destinationWorkspaceId })
        #expect(result.sourceWindowId == windowId)
        #expect(result.sourceWorkspaceId == sourceWorkspace.id)
        #expect(result.destinationWindowId == windowId)
        #expect(manager.tabs.count == originalWorkspaceCount + 1)
        #expect(destinationWorkspace.title == "Build logs")
        #expect(destinationWorkspace.panels.count == 1)
        #expect(destinationWorkspace.panels[movedPanel.id] != nil)
        #expect(sourceWorkspace.panels[movedPanel.id] == nil)
        #expect(sourceWorkspace.panels[remainingPanelId] != nil)
        #expect(result.paneId == destinationWorkspace.paneId(forPanelId: movedPanel.id)?.id)
    }

    @Test
    func moveSurfaceToNewWorkspaceFlushesPendingTitleBeforeDerivingDestinationTitle() async throws {
        let suiteName = "AppDelegateMoveSurfaceTitle.\(UUID().uuidString)"
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
            panelTitleUpdateScheduler: PanelTitleUpdateCoalescer(
                schedule: scheduler.schedule(delay:action:)
            )
        )
        let app = AppDelegate()
        let windowId = UUID()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let remainingPanelId = try #require(workspace.focusedPanelId)
        let movedPanel = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false))
        let movedTitle = "Moved Surface Title - grok"

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: workspace.terminalPanel(for: movedPanel.id)?.surface,
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: movedPanel.id,
                GhosttyNotificationKey.title: movedTitle
            ]
        )

        await drainMainQueue()
        #expect(scheduler.delays == [0.5])
        #expect(workspace.panelTitles[movedPanel.id] != movedTitle)
        #expect(workspace.title != movedTitle)

        let result = try #require(app.moveSurfaceToNewWorkspace(
            panelId: movedPanel.id,
            focus: false,
            focusWindow: false
        ))
        let destinationWorkspace = try #require(manager.tabs.first { $0.id == result.destinationWorkspaceId })

        #expect(workspace.panels[movedPanel.id] == nil)
        #expect(workspace.panels[remainingPanelId] != nil)
        #expect(destinationWorkspace.customTitle == movedTitle)
        #expect(destinationWorkspace.title == movedTitle)
        #expect(destinationWorkspace.panelTitle(panelId: movedPanel.id) == movedTitle)

        scheduler.fire(at: 0)
        #expect(destinationWorkspace.title == movedTitle)
        #expect(destinationWorkspace.panelTitle(panelId: movedPanel.id) == movedTitle)
    }

    @Test
    func moveSurfaceToNewWorkspacePreservesTerminalTextBoxStateWhenDefaultsEnabled() throws {
        let defaults = UserDefaults.standard
        let showKey = TerminalTextBoxInputSettings.showOnNewTerminalsKey
        let focusKey = TerminalTextBoxInputSettings.focusOnNewTerminalsKey
        let previousShowValue = defaults.object(forKey: showKey)
        let previousFocusValue = defaults.object(forKey: focusKey)
        defer {
            if let previousShowValue {
                defaults.set(previousShowValue, forKey: showKey)
            } else {
                defaults.removeObject(forKey: showKey)
            }
            if let previousFocusValue {
                defaults.set(previousFocusValue, forKey: focusKey)
            } else {
                defaults.removeObject(forKey: focusKey)
            }
        }

        defaults.set(false, forKey: showKey)
        defaults.set(false, forKey: focusKey)

        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let sourceWorkspace = try #require(manager.selectedWorkspace)
        let sourcePaneId = try #require(sourceWorkspace.bonsplitController.allPaneIds.first)
        let movedPanel = try #require(sourceWorkspace.newTerminalSurface(inPane: sourcePaneId, focus: false))
        #expect(!movedPanel.isTextBoxActive)

        defaults.set(true, forKey: showKey)
        defaults.set(true, forKey: focusKey)

        let result = try #require(app.moveSurfaceToNewWorkspace(
            panelId: movedPanel.id,
            focus: false,
            focusWindow: false
        ))

        let destinationWorkspace = try #require(manager.tabs.first { $0.id == result.destinationWorkspaceId })
        let destinationPanel = try #require(destinationWorkspace.panels[movedPanel.id] as? TerminalPanel)
        #expect(!destinationPanel.isTextBoxActive)
        #expect(destinationPanel.preferredFocusIntentForActivation() != .terminal(.textBoxInput))
    }

    @Test
    func moveBrowserBonsplitTabToNewWorkspaceRequestsAddressBarFocus() throws {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let sourceWorkspace = try #require(manager.selectedWorkspace)
        let sourcePaneId = try #require(sourceWorkspace.bonsplitController.allPaneIds.first)
        let browserPanel = try #require(
            sourceWorkspace.newBrowserSurface(
                inPane: sourcePaneId,
                url: URL(string: "https://example.com")!,
                focus: false
            )
        )
        let browserTabId = try #require(sourceWorkspace.surfaceIdFromPanelId(browserPanel.id)?.uuid)
        browserPanel.noteWebViewFocused()
        #expect(browserPanel.preferredFocusIntentForActivation() == .browser(.webView))

        let result = try #require(app.moveBonsplitTabToNewWorkspace(
            tabId: browserTabId,
            focus: true,
            focusWindow: false
        ))

        let destinationWorkspace = try #require(manager.tabs.first { $0.id == result.destinationWorkspaceId })
        let movedBrowserPanel = try #require(destinationWorkspace.panels[browserPanel.id] as? BrowserPanel)
        #expect(destinationWorkspace.panels.count == 1)
        #expect(!destinationWorkspace.panels.values.contains { $0 is TerminalPanel })
        #expect(destinationWorkspace.focusedPanelId == movedBrowserPanel.id)
        #expect(movedBrowserPanel.preferredFocusIntentForActivation() == .browser(.addressBar))
    }

    @Test
    func moveSurfaceToNewWorkspaceRejectsOnlyPanel() throws {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let sourceWorkspace = try #require(manager.selectedWorkspace)
        let onlyPanelId = try #require(sourceWorkspace.focusedTerminalPanel?.id)

        #expect(!app.canMoveSurfaceToNewWorkspace(panelId: onlyPanelId))
        #expect(app.moveSurfaceToNewWorkspace(panelId: onlyPanelId, focus: false, focusWindow: false) == nil)
        #expect(manager.tabs.count == 1)
        #expect(sourceWorkspace.panels[onlyPanelId] != nil)
    }

    @Test
    func moveTerminalBonsplitTabToExistingWorkspaceClosesEmptiedSourceWorkspace() throws {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let sourceWorkspace = try #require(manager.selectedWorkspace)
        let movedPanelId = try #require(sourceWorkspace.focusedTerminalPanel?.id)
        let movedBonsplitTabId = try #require(sourceWorkspace.surfaceIdFromPanelId(movedPanelId)?.uuid)
        let destinationWorkspace = manager.addWorkspace(title: "Operations", select: false)
        let destinationOriginalPanelId = try #require(destinationWorkspace.focusedTerminalPanel?.id)

        #expect(app.canMoveBonsplitTab(tabId: movedBonsplitTabId, toWorkspace: destinationWorkspace.id))
        #expect(app.moveBonsplitTab(
            tabId: movedBonsplitTabId,
            toWorkspace: destinationWorkspace.id,
            focus: false,
            focusWindow: false
        ))

        #expect(!manager.tabs.contains { $0.id == sourceWorkspace.id })
        #expect(manager.tabs.map(\.id) == [destinationWorkspace.id])
        #expect(sourceWorkspace.panels.isEmpty)
        #expect(destinationWorkspace.panels[movedPanelId] != nil)
        #expect(destinationWorkspace.panels[destinationOriginalPanelId] != nil)
        #expect(destinationWorkspace.panels.count == 2)
    }

    @Test
    func moveSurfaceToExistingWorkspaceClosesEmptiedSourceWorkspaceAndFocusesDestination() throws {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let sourceWorkspace = try #require(manager.selectedWorkspace)
        let movedPanelId = try #require(sourceWorkspace.focusedTerminalPanel?.id)
        let destinationWorkspace = manager.addWorkspace(title: "Operations", select: false)
        let destinationOriginalPanelId = try #require(destinationWorkspace.focusedTerminalPanel?.id)

        #expect(app.moveSurface(
            panelId: movedPanelId,
            toWorkspace: destinationWorkspace.id,
            focus: true,
            focusWindow: false
        ))

        #expect(!manager.tabs.contains { $0.id == sourceWorkspace.id })
        #expect(manager.tabs.map(\.id) == [destinationWorkspace.id])
        #expect(sourceWorkspace.panels.isEmpty)
        #expect(destinationWorkspace.panels[movedPanelId] != nil)
        #expect(destinationWorkspace.panels[destinationOriginalPanelId] != nil)
        #expect(destinationWorkspace.panels.count == 2)
        #expect(manager.selectedWorkspace?.id == destinationWorkspace.id)
        #expect(destinationWorkspace.focusedPanelId == movedPanelId)
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
