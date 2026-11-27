import Foundation
import Testing
import XCTest
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

        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let sourcePaneId = try XCTUnwrap(sourceWorkspace.bonsplitController.allPaneIds.first)
        let remainingPanelId = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)
        let movedPanel = try XCTUnwrap(sourceWorkspace.newTerminalSurface(inPane: sourcePaneId, focus: false))
        sourceWorkspace.setPanelCustomTitle(panelId: movedPanel.id, title: "Build logs")

        let originalWorkspaceCount = manager.tabs.count
        let result = try XCTUnwrap(app.moveSurfaceToNewWorkspace(
            panelId: movedPanel.id,
            focus: false,
            focusWindow: false
        ))

        let destinationWorkspace = try XCTUnwrap(manager.tabs.first { $0.id == result.destinationWorkspaceId })
        #expect(result.sourceWindowId == windowId)
        #expect(result.sourceWorkspaceId == sourceWorkspace.id)
        #expect(result.destinationWindowId == windowId)
        #expect(manager.tabs.count == originalWorkspaceCount + 1)
        #expect(destinationWorkspace.title == "Build logs")
        #expect(destinationWorkspace.customTitle == "Build logs")
        #expect(destinationWorkspace.customTitleSource == .user)
        #expect(destinationWorkspace.panels.count == 1)
        #expect(destinationWorkspace.panels[movedPanel.id] != nil)
        #expect(sourceWorkspace.panels[movedPanel.id] == nil)
        #expect(sourceWorkspace.panels[remainingPanelId] != nil)
        #expect(result.paneId == destinationWorkspace.paneId(forPanelId: movedPanel.id)?.id)
    }

    @Test
    func moveSurfaceToNewWorkspaceFlushesPendingTitleBeforeDerivingDestinationTitle() async throws {
        let suiteName = "AppDelegateMoveSurfaceTitle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
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
        let app = AppDelegate()
        let windowId = UUID()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let remainingPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let movedPanel = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: false))
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

        let result = try XCTUnwrap(app.moveSurfaceToNewWorkspace(
            panelId: movedPanel.id,
            focus: false,
            focusWindow: false
        ))
        let destinationWorkspace = try XCTUnwrap(manager.tabs.first { $0.id == result.destinationWorkspaceId })

        #expect(workspace.panels[movedPanel.id] == nil)
        #expect(workspace.panels[remainingPanelId] != nil)
        #expect(destinationWorkspace.customTitle == nil)
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

        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let sourcePaneId = try XCTUnwrap(sourceWorkspace.bonsplitController.allPaneIds.first)
        let movedPanel = try XCTUnwrap(sourceWorkspace.newTerminalSurface(inPane: sourcePaneId, focus: false))
        #expect(!movedPanel.isTextBoxActive)

        defaults.set(true, forKey: showKey)
        defaults.set(true, forKey: focusKey)

        let result = try XCTUnwrap(app.moveSurfaceToNewWorkspace(
            panelId: movedPanel.id,
            focus: false,
            focusWindow: false
        ))

        let destinationWorkspace = try XCTUnwrap(manager.tabs.first { $0.id == result.destinationWorkspaceId })
        let destinationPanel = try XCTUnwrap(destinationWorkspace.panels[movedPanel.id] as? TerminalPanel)
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

        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let sourcePaneId = try XCTUnwrap(sourceWorkspace.bonsplitController.allPaneIds.first)
        let browserPanel = try XCTUnwrap(
            sourceWorkspace.newBrowserSurface(
                inPane: sourcePaneId,
                url: try XCTUnwrap(URL(string: "https://example.com")),
                focus: false
            )
        )
        let browserTabId = try XCTUnwrap(sourceWorkspace.surfaceIdFromPanelId(browserPanel.id)?.uuid)
        browserPanel.noteWebViewFocused()
        #expect(browserPanel.preferredFocusIntentForActivation() == .browser(.webView))

        let result = try XCTUnwrap(app.moveBonsplitTabToNewWorkspace(
            tabId: browserTabId,
            focus: true,
            focusWindow: false
        ))

        let destinationWorkspace = try XCTUnwrap(manager.tabs.first { $0.id == result.destinationWorkspaceId })
        let movedBrowserPanel = try XCTUnwrap(destinationWorkspace.panels[browserPanel.id] as? BrowserPanel)
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

        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let onlyPanelId = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)

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

        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let movedPanelId = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)
        let movedBonsplitTabId = try XCTUnwrap(sourceWorkspace.surfaceIdFromPanelId(movedPanelId)?.uuid)
        let destinationWorkspace = manager.addWorkspace(title: "Operations", select: false)
        let destinationOriginalPanelId = try XCTUnwrap(destinationWorkspace.focusedTerminalPanel?.id)

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

    /// Regression for https://github.com/manaflow-ai/cmux/issues/4946.
    ///
    /// Detaching a tab with only a process-derived title into a new workspace
    /// must not pin the destination workspace's `customTitle`. Pinning blocks
    /// the OSC-driven `applyProcessTitle` pipeline, which is what feeds claude
    /// code's dynamic `✳ <topic>` titles into the workspace row.
    @Test("Move surface to new workspace does not pin custom title and allows later OSC updates")
    func moveSurfaceToNewWorkspaceDoesNotPinCustomTitleAndAllowsLaterOSCUpdates() throws {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let sourceWorkspace = try #require(manager.selectedWorkspace)
        let sourcePaneId = try #require(sourceWorkspace.bonsplitController.allPaneIds.first)
        let movedPanel = try #require(sourceWorkspace.newTerminalSurface(inPane: sourcePaneId, focus: false))

        // Seed the source panel's process-derived title with what a shell
        // PROMPT_COMMAND typically emits before the user starts claude. This
        // is the value the buggy code pins onto the detached workspace's
        // `customTitle`.
        #expect(sourceWorkspace.updatePanelTitle(panelId: movedPanel.id, title: "user@host:~/git/repo"))

        let result = try #require(app.moveSurfaceToNewWorkspace(
            panelId: movedPanel.id,
            focus: false,
            focusWindow: false
        ))
        let destinationWorkspace = try #require(manager.tabs.first { $0.id == result.destinationWorkspaceId })

        // 1. The destination workspace must not have its title pinned. A
        //    drag-created workspace should behave like one created via
        //    "New Workspace" — `customTitle` stays `nil` until the user
        //    renames it explicitly.
        #expect(
            destinationWorkspace.customTitle == nil,
            "Detached workspace must not pin customTitle; pinning blocks OSC title updates."
        )

        // 2. Simulate the OSC SET_TITLE that claude emits once it starts
        //    rendering its first message. With customTitle pinned, this
        //    call short-circuits inside `applyProcessTitle` and the
        //    workspace title never moves off the shell prompt.
        let claudeTitle = "✳ Investigate workspace title bug"
        destinationWorkspace.applyProcessTitle(claudeTitle)
        #expect(
            destinationWorkspace.title == claudeTitle,
            "applyProcessTitle must update self.title on a freshly detached workspace."
        )
    }

    @Test("Move surface to new workspace preserves manually renamed tab title")
    func moveSurfaceToNewWorkspacePreservesManuallyRenamedTabTitle() throws {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let sourceWorkspace = try #require(manager.selectedWorkspace)
        let sourcePaneId = try #require(sourceWorkspace.bonsplitController.allPaneIds.first)
        let movedPanel = try #require(sourceWorkspace.newTerminalSurface(inPane: sourcePaneId, focus: false))
        #expect(sourceWorkspace.updatePanelTitle(panelId: movedPanel.id, title: "user@host:~/git/repo"))
        sourceWorkspace.setPanelCustomTitle(panelId: movedPanel.id, title: "Deploy logs")

        let result = try #require(app.moveSurfaceToNewWorkspace(
            panelId: movedPanel.id,
            focus: false,
            focusWindow: false
        ))
        let destinationWorkspace = try #require(manager.tabs.first { $0.id == result.destinationWorkspaceId })

        #expect(destinationWorkspace.title == "Deploy logs")
        #expect(destinationWorkspace.customTitle == "Deploy logs")

        destinationWorkspace.applyProcessTitle("claude investigation")
        #expect(
            destinationWorkspace.title == "Deploy logs",
            "A manually renamed tab should stay pinned after it becomes a workspace."
        )
    }

    @Test(arguments: [Workspace.CustomTitleSource.auto, .remote])
    func moveSurfaceToNewWorkspacePreservesInheritedTitleSource(source: Workspace.CustomTitleSource) throws {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let sourceWorkspace = try #require(manager.selectedWorkspace)
        let sourcePaneId = try #require(sourceWorkspace.bonsplitController.allPaneIds.first)
        let movedPanel = try #require(sourceWorkspace.newTerminalSurface(inPane: sourcePaneId, focus: false))
        #expect(sourceWorkspace.setPanelCustomTitle(panelId: movedPanel.id, title: "Agent task", source: source))

        let result = try #require(app.moveSurfaceToNewWorkspace(
            panelId: movedPanel.id,
            focus: false,
            focusWindow: false
        ))
        let destinationWorkspace = try #require(manager.tabs.first { $0.id == result.destinationWorkspaceId })

        #expect(destinationWorkspace.customTitle == "Agent task")
        #expect(destinationWorkspace.customTitleSource == source)
        #expect(destinationWorkspace.panelCustomTitleSources[movedPanel.id] == source)

        let updated = manager.setCustomTitle(tabId: destinationWorkspace.id, title: "Updated agent task", source: .auto)
        #expect(updated == (source == .auto))
        #expect(destinationWorkspace.title == (source == .auto ? "Updated agent task" : "Agent task"))
    }

    @Test("Move surface to new workspace pins explicit caller title")
    func moveSurfaceToNewWorkspacePinsExplicitCallerTitle() throws {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let sourceWorkspace = try #require(manager.selectedWorkspace)
        let sourcePaneId = try #require(sourceWorkspace.bonsplitController.allPaneIds.first)
        let movedPanel = try #require(sourceWorkspace.newTerminalSurface(inPane: sourcePaneId, focus: false))
        sourceWorkspace.setPanelCustomTitle(panelId: movedPanel.id, title: "Agent task", source: .auto)

        let result = try #require(app.moveSurfaceToNewWorkspace(
            panelId: movedPanel.id,
            title: "Deploy logs",
            focus: false,
            focusWindow: false
        ))
        let destinationWorkspace = try #require(manager.tabs.first { $0.id == result.destinationWorkspaceId })

        #expect(destinationWorkspace.title == "Deploy logs")
        #expect(destinationWorkspace.customTitle == "Deploy logs")
        #expect(destinationWorkspace.customTitleSource == .user)
        #expect(!manager.setCustomTitle(tabId: destinationWorkspace.id, title: "Updated agent task", source: .auto))

        destinationWorkspace.applyProcessTitle("✳ Investigate workspace title bug")
        #expect(
            destinationWorkspace.title == "Deploy logs",
            "Explicit caller title should remain pinned until the user or caller changes it."
        )
    }

    @Test("Move surface to new workspace ignores whitespace-only caller title pin")
    func moveSurfaceToNewWorkspaceIgnoresWhitespaceOnlyCallerTitlePin() throws {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let sourceWorkspace = try #require(manager.selectedWorkspace)
        let sourcePaneId = try #require(sourceWorkspace.bonsplitController.allPaneIds.first)
        let movedPanel = try #require(sourceWorkspace.newTerminalSurface(inPane: sourcePaneId, focus: false))
        sourceWorkspace.setPanelCustomTitle(panelId: movedPanel.id, title: "user@host:~/git/repo")

        let result = try #require(app.moveSurfaceToNewWorkspace(
            panelId: movedPanel.id,
            title: " \t\n ",
            focus: false,
            focusWindow: false
        ))
        let destinationWorkspace = try #require(manager.tabs.first { $0.id == result.destinationWorkspaceId })

        #expect(destinationWorkspace.customTitle == nil)

        destinationWorkspace.applyProcessTitle("claude investigation")
        #expect(
            destinationWorkspace.title == "claude investigation",
            "Whitespace-only caller titles must not pin the workspace title."
        )
    }

    @Test
    func moveSurfaceToExistingWorkspaceClosesEmptiedSourceWorkspaceAndFocusesDestination() throws {
        let app = AppDelegate()
        let windowId = UUID()
        let manager = TabManager()
        app.registerMainWindowContextForTesting(windowId: windowId, tabManager: manager)
        defer { app.unregisterMainWindowContextForTesting(windowId: windowId) }

        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let movedPanelId = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel?.id)
        let destinationWorkspace = manager.addWorkspace(title: "Operations", select: false)
        let destinationOriginalPanelId = try XCTUnwrap(destinationWorkspace.focusedTerminalPanel?.id)

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
