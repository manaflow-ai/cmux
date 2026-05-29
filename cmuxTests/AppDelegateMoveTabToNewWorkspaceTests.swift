import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("AppDelegate move tab to new workspace", .serialized)
struct AppDelegateMoveTabToNewWorkspaceTests {
    @Test("Move surface to new workspace creates single-panel workspace from panel title")
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

    @Test("Move surface to new workspace preserves terminal text box state when defaults enabled")
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

    @Test("Move browser bonsplit tab to new workspace requests address bar focus")
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
                url: try #require(URL(string: "https://example.com")),
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

    @Test("Move surface to new workspace rejects only panel")
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

    @Test("Move terminal bonsplit tab to existing workspace closes emptied source workspace")
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

    /// Regression for https://github.com/manaflow-ai/cmux/issues/4946.
    ///
    /// Detaching a tab into a new workspace must not pin the destination
    /// workspace's `customTitle`. Pinning blocks the OSC-driven
    /// `applyProcessTitle` pipeline, which is what feeds claude code's
    /// dynamic `✳ <topic>` titles into the workspace row.
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

        // Seed the source panel's title with what a shell PROMPT_COMMAND
        // typically emits before the user starts claude. This is the value
        // the buggy code pins onto the detached workspace's `customTitle`.
        sourceWorkspace.setPanelCustomTitle(panelId: movedPanel.id, title: "user@host:~/git/repo")

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
        sourceWorkspace.setPanelCustomTitle(panelId: movedPanel.id, title: "user@host:~/git/repo")

        let result = try #require(app.moveSurfaceToNewWorkspace(
            panelId: movedPanel.id,
            title: "Deploy logs",
            focus: false,
            focusWindow: false
        ))
        let destinationWorkspace = try #require(manager.tabs.first { $0.id == result.destinationWorkspaceId })

        #expect(destinationWorkspace.title == "Deploy logs")
        #expect(destinationWorkspace.customTitle == "Deploy logs")

        destinationWorkspace.applyProcessTitle("✳ Investigate workspace title bug")
        #expect(
            destinationWorkspace.title == "Deploy logs",
            "Explicit caller title should remain pinned until the user or caller changes it."
        )
    }

    @Test("Move surface to existing workspace closes emptied source workspace and focuses destination")
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
}
