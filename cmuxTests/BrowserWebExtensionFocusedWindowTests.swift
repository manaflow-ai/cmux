import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct BrowserWebExtensionFocusedWindowTests {
    @MainActor
    @Test
    @available(macOS 15.4, *)
    func keyWindowSwitchRestoresThatWindowsActiveExtensionTab() throws {
        let support = BrowserWebExtensionSupport()
        let firstPanel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://first.example"),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let secondPanel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "https://second.example"),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        firstWindow.contentView = firstPanel.webView
        secondWindow.contentView = secondPanel.webView
        defer {
            firstPanel.close()
            secondPanel.close()
            firstWindow.close()
            secondWindow.close()
        }

        support.register(panel: firstPanel)
        support.register(panel: secondPanel)
        support.noteActivated(panelID: firstPanel.id)
        NSApp.activate()
        secondWindow.orderFront(nil)
        secondWindow.makeKey()
        #expect(secondWindow.isKeyWindow)
        support.noteWindowBecameKey(secondWindow)
        support.noteActivated(panelID: secondPanel.id)
        #expect(support.activePanelID == secondPanel.id)

        firstWindow.orderFront(nil)
        firstWindow.makeKey()
        #expect(firstWindow.isKeyWindow)
        support.noteWindowBecameKey(firstWindow)

        #expect(support.activePanelID == firstPanel.id)
        let firstAdapter = try #require(support.webExtensionWindow(for: firstWindow))
        let secondAdapter = try #require(support.webExtensionWindow(for: secondWindow))
        #expect((firstAdapter as AnyObject) !== (secondAdapter as AnyObject))
        #expect((support.focusedWebExtensionWindow(for: firstWindow) as AnyObject?) === (firstAdapter as AnyObject))
        let unrelatedWindow = NSWindow()
        #expect(support.webExtensionWindow(for: unrelatedWindow) == nil)
        #expect(support.focusedWebExtensionWindow(for: unrelatedWindow) == nil)
        #expect(support.focusedWebExtensionWindow(for: nil) == nil)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func movingPanelReconcilesItsNativeWindowIdentity() throws {
        let support = BrowserWebExtensionSupport()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let sourceWindow = NSWindow()
        let destinationWindow = NSWindow()
        sourceWindow.contentView = panel.webView
        defer {
            support.unregister(panelID: panel.id)
            destinationWindow.contentView = nil
            panel.close()
            sourceWindow.close()
            destinationWindow.close()
        }

        support.register(panel: panel)
        let sourceAdapter = try #require(support.webExtensionWindow(for: sourceWindow))

        sourceWindow.contentView = nil
        destinationWindow.contentView = panel.webView
        support.noteWindowChanged(panelID: panel.id)

        let destinationAdapter = try #require(support.webExtensionWindow(for: destinationWindow))
        #expect((sourceAdapter as AnyObject) !== (destinationAdapter as AnyObject))
        #expect(support.webExtensionWindow(for: sourceWindow) == nil)
        #expect(support.normalWindowAdapters.count == 1)
        #expect((support.normalWindowAdapters.first as AnyObject?) === (destinationAdapter as AnyObject))
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func registeredPanelAcquiresItsFirstNativeWindow() throws {
        let support = BrowserWebExtensionSupport()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let window = NSWindow()
        defer {
            support.unregister(panelID: panel.id)
            window.contentView = nil
            panel.close()
            window.close()
        }

        support.register(panel: panel)
        #expect(support.windowAdapter(for: panel.id) == nil)
        #expect(!support.openTabNotificationPanelIDs.contains(panel.id))

        support.noteWindowChanged(panelID: panel.id, nativeWindow: window)

        let adapter = try #require(support.windowAdapter(for: panel.id))
        #expect((support.webExtensionWindow(for: window) as AnyObject?) === (adapter as AnyObject))
        #expect(support.openTabNotificationPanelIDs.contains(panel.id))
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func registeringWindowlessPanelDoesNotSetGlobalActiveTab() {
        let support = BrowserWebExtensionSupport()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        defer { panel.close() }

        support.register(panel: panel)
        #expect(support.activePanelID == nil)

        support.unregister(panelID: panel.id)

        #expect(support.activePanelID == nil)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func closingDockBrowserUsesSelectedSuccessor() throws {
        let support = BrowserWebExtensionSupport()
        let dock = DockSplitStore(
            workspaceId: UUID(),
            scope: .global,
            baseDirectoryProvider: { nil },
            browserAvailabilityProvider: { true },
            browserWebExtensionHost: support
        )
        let window = NSWindow()
        defer {
            dock.setVisibleInUI(false)
            dock.closeAllPanels()
            window.close()
        }
        let paneID = try #require(dock.resolvePane(requestedPaneID: nil))
        let closingPanelID = try #require(dock.newSurface(kind: .browser, inPane: paneID, focus: true))
        let selectedSuccessorID = try #require(dock.newSurface(kind: .browser, inPane: paneID, focus: false))
        let lastRegisteredPanelID = try #require(dock.newSurface(kind: .browser, inPane: paneID, focus: false))
        let lastRegisteredTabID = try #require(dock.surfaceId(forPanelId: lastRegisteredPanelID))
        #expect(dock.bonsplitController.reorderTab(lastRegisteredTabID, toIndex: 0))
        dock.setVisibleInUI(true)
        dock.reconcileBrowserWebExtensionWindows(in: window)
        dock.focusPanel(closingPanelID)

        #expect(support.activePanelID(in: window) == closingPanelID)
        #expect(dock.closePanel(closingPanelID, force: true))

        #expect(dock.focusedPanelId == selectedSuccessorID)
        #expect(support.activePanelID(in: window) == selectedSuccessorID)
        #expect(support.activePanelID(in: window) != lastRegisteredPanelID)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func registeringBackgroundPanelPreservesPerWindowActiveTabWithoutGlobalFallback() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let support = BrowserWebExtensionSupport()
        let activePanel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let backgroundPanel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let window = NSWindow()
        let terminalWindow = NSWindow()
        let terminalManager = TabManager(autoWelcomeIfNeeded: false)
        let terminalWindowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: terminalManager,
            window: terminalWindow
        )
        let contentView = NSView()
        window.contentView = contentView
        contentView.addSubview(activePanel.webView)
        contentView.addSubview(backgroundPanel.webView)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: terminalWindowID)
            terminalManager.tabs.forEach { $0.teardownAllPanels() }
            support.unregister(panelID: activePanel.id)
            support.unregister(panelID: backgroundPanel.id)
            window.contentView = nil
            activePanel.close()
            backgroundPanel.close()
            window.close()
            terminalWindow.close()
        }

        support.register(panel: activePanel)
        support.noteActivated(panelID: activePanel.id)
        support.noteWindowBecameKey(terminalWindow)
        #expect(support.activePanelID == nil)
        support.register(panel: backgroundPanel)

        #expect(support.activePanelID == nil)
        #expect(support.activePanelID(in: window) == activePanel.id)
        #expect(support.isPanelActiveInWindow(activePanel.id))
        #expect(!support.isPanelActiveInWindow(backgroundPanel.id))
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func closingNativeWindowRemovesAdapterAndReopensTabWhenReattached() throws {
        let support = BrowserWebExtensionSupport()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let firstWindow = NSWindow()
        let replacementWindow = NSWindow()
        firstWindow.contentView = panel.webView
        defer {
            support.unregister(panelID: panel.id)
            replacementWindow.contentView = nil
            panel.close()
            firstWindow.close()
            replacementWindow.close()
        }

        support.register(panel: panel)
        let firstAdapter = try #require(support.windowAdapter(for: panel.id))

        _ = support.noteWindowClosed(firstWindow)

        #expect(support.windowAdapter(for: panel.id) == nil)
        #expect(support.webExtensionWindow(for: firstWindow) == nil)
        #expect(support.normalWindowAdapters.isEmpty)
        #expect(support.activePanelID == nil)
        #expect(!support.openTabNotificationPanelIDs.contains(panel.id))

        firstWindow.contentView = nil
        replacementWindow.contentView = panel.webView
        support.noteWindowChanged(panelID: panel.id, nativeWindow: replacementWindow)

        let replacementAdapter = try #require(support.windowAdapter(for: panel.id))
        #expect((firstAdapter as AnyObject) !== (replacementAdapter as AnyObject))
        #expect(support.openTabNotificationPanelIDs.contains(panel.id))
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func orphanedContextDiscardsExtensionWindowOwnership() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let support = BrowserWebExtensionSupport()
        let tabManager = TabManager(browserWebExtensionHost: support)
        let workspace = try #require(tabManager.selectedWorkspace)
        let paneID = try #require(workspace.bonsplitController.allPaneIds.first)
        let panel = try #require(workspace.newBrowserSurface(inPane: paneID, focus: false))
        let window = NSWindow()
        _ = tabManager.setOwningWindow(window)
        let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: tabManager)
        var contextIsRegistered = true
        defer {
            if contextIsRegistered {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            }
            workspace.teardownAllPanels()
            window.close()
        }

        #expect(support.tabAdapters[panel.id] != nil)
        #expect(support.windowAdapter(for: panel.id) != nil)
        tabManager.window = nil

        appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
        contextIsRegistered = false

        #expect(support.tabAdapters[panel.id] == nil)
        #expect(support.windowAdapter(for: panel.id) == nil)
        #expect(!support.openTabNotificationPanelIDs.contains(panel.id))
        #expect(support.normalWindowAdapters.isEmpty)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func addingBrowserTabToKeyWindowMakesThatWindowGloballyActive() {
        let support = BrowserWebExtensionSupport()
        let previousPanel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let keyWindowPanel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let previousWindow = NSWindow()
        let keyWindow = NSWindow()
        previousWindow.contentView = previousPanel.webView
        defer {
            support.unregister(panelID: previousPanel.id)
            support.unregister(panelID: keyWindowPanel.id)
            previousWindow.contentView = nil
            keyWindow.contentView = nil
            previousPanel.close()
            keyWindowPanel.close()
            previousWindow.close()
            keyWindow.close()
        }

        support.register(panel: previousPanel)
        support.noteActivated(panelID: previousPanel.id)
        support.register(panel: keyWindowPanel)
        #expect(support.activePanelID == previousPanel.id)

        NSApp.activate()
        keyWindow.orderFront(nil)
        keyWindow.makeKey()
        #expect(keyWindow.isKeyWindow)
        keyWindow.contentView = keyWindowPanel.webView
        support.noteWindowChanged(panelID: keyWindowPanel.id, nativeWindow: keyWindow)

        #expect(support.activePanelID == keyWindowPanel.id)
        #expect(support.activePanelID(in: keyWindow) == keyWindowPanel.id)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func windowDockPanelsReconcileToReplacementNativeWindow() throws {
        let support = BrowserWebExtensionSupport()
        let dock = DockSplitStore(
            workspaceId: UUID(),
            scope: .global,
            baseDirectoryProvider: { nil },
            browserAvailabilityProvider: { true },
            browserWebExtensionHost: support
        )
        let tabManager = TabManager(
            autoWelcomeIfNeeded: false,
            browserWebExtensionHost: support
        )
        let firstWindow = NSWindow()
        let replacementWindow = NSWindow()
        defer {
            tabManager.setOwningWindow(nil)
            dock.closeAllPanels()
            firstWindow.close()
            replacementWindow.close()
        }
        let paneID = try #require(dock.resolvePane(requestedPaneID: nil))
        let panelID = try #require(dock.newSurface(kind: .browser, inPane: paneID, focus: true))
        let activePanelID = try #require(dock.newSurface(kind: .browser, inPane: paneID, focus: true))

        tabManager.setOwningWindow(firstWindow)
        dock.reconcileBrowserWebExtensionWindows(in: firstWindow)
        support.noteActivated(panelID: activePanelID)
        let firstAdapter = try #require(support.windowAdapter(for: panelID))

        let previouslyActivePanelID = tabManager.setOwningWindow(replacementWindow)
        #expect(previouslyActivePanelID == activePanelID)
        #expect(support.windowAdapter(for: panelID) == nil)
        dock.reconcileBrowserWebExtensionWindows(in: replacementWindow)
        if let previouslyActivePanelID {
            support.noteActivated(panelID: previouslyActivePanelID)
        }

        let replacementAdapter = try #require(support.windowAdapter(for: panelID))
        #expect((firstAdapter as AnyObject) !== (replacementAdapter as AnyObject))
        #expect((support.webExtensionWindow(for: replacementWindow) as AnyObject?) === (replacementAdapter as AnyObject))
        #expect(support.activePanelID == nil)
        #expect(support.activePanelID(in: replacementWindow) == activePanelID)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func normalWindowCreationReplacesBootstrapTerminalAndSelectsFirstBrowser() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let support = BrowserWebExtensionSupport()
        let previousHost = appDelegate.browserWebExtensionHost
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        appDelegate.browserWebExtensionHost = support
        BrowserAvailabilitySettings.setDisabled(false)
        let foregroundPanel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let foregroundWindow = NSWindow()
        foregroundWindow.contentView = foregroundPanel.webView
        defer {
            support.unregister(panelID: foregroundPanel.id)
            foregroundWindow.contentView = nil
            foregroundPanel.close()
            foregroundWindow.close()
            appDelegate.browserWebExtensionHost = previousHost
            BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled)
        }
        support.register(panel: foregroundPanel)
        NSApp.activate()
        foregroundWindow.orderFront(nil)
        foregroundWindow.makeKey()
        #expect(foregroundWindow.isKeyWindow)
        support.noteWindowBecameKey(foregroundWindow)
        support.noteActivated(panelID: foregroundPanel.id)
        #expect(support.activePanelID == foregroundPanel.id)

        let adapter = try #require(support.openNormalBrowserWindow(
            requestedTabs: [(nil, nil), (nil, nil)],
            shouldFocus: false
        ))
        let window = try #require(adapter.hostWindow)
        let context = try #require(appDelegate.contextForMainTerminalWindow(window))
        var didCloseWindow = false
        defer {
            if !didCloseWindow {
                _ = appDelegate.closeMainWindow(windowId: context.windowId, recordHistory: false)
            }
        }
        let workspace = try #require(context.tabManager.selectedWorkspace)
        let browserPanels = workspace.panels.values.compactMap { $0 as? BrowserPanel }
        let focusedPanelID = try #require(workspace.focusedPanelId)

        #expect(workspace.panels.count == 2)
        #expect(browserPanels.count == 2)
        #expect(workspace.panels.values.allSatisfy { $0 is BrowserPanel })
        #expect(browserPanels.contains { $0.id == focusedPanelID })
        #expect(support.activePanelID(in: window) == focusedPanelID)
        #expect(support.activePanelID == foregroundPanel.id)
        didCloseWindow = appDelegate.closeMainWindow(windowId: context.windowId, recordHistory: false)
        #expect(didCloseWindow)
        #expect(browserPanels.allSatisfy { support.tabAdapters[$0.id] == nil })
    }
}
