import AppKit
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct BrowserWebExtensionReviewRegressionTests {
    @MainActor
    @Test
    @available(macOS 15.4, *)
    func extensionCreatesFirstBrowserTabInActiveTerminalWindow() throws {
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let support = BrowserWebExtensionSupport()
        let tabManager = TabManager(browserWebExtensionHost: support)
        let workspace = try #require(tabManager.selectedWorkspace)
        #expect(workspace.panels.values.allSatisfy { !($0 is BrowserPanel) })

        let adapter = support.openBrowserTab(
            in: tabManager,
            url: nil,
            shouldActivate: false,
            webViewConfiguration: nil
        )

        let panel = try #require(adapter?.panel)
        defer { _ = workspace.closePanel(panel.id, force: true) }
        #expect(panel.workspaceId == workspace.id)
        #expect(workspace.panels[panel.id] === panel)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func openingExtensionPopupRequestPreservesMethodBodyAndHeaders() throws {
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let support = BrowserWebExtensionSupport()
        let tabManager = TabManager(browserWebExtensionHost: support)
        let workspace = try #require(tabManager.selectedWorkspace)
        let body = Data("credential=secret".utf8)
        var request = URLRequest(url: try #require(URL(string: "https://popup.example/login")))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("popup-token", forHTTPHeaderField: "X-Popup-Token")

        let adapter = support.openBrowserTab(
            in: tabManager,
            url: nil,
            initialRequest: request,
            shouldActivate: false,
            webViewConfiguration: nil
        )

        let panel = try #require(adapter?.panel)
        defer { _ = workspace.closePanel(panel.id, force: true) }
        let openedRequest = try #require(panel.navigationDelegate?.lastAttemptedRequest)
        #expect(openedRequest.url == request.url)
        #expect(openedRequest.httpMethod == "POST")
        #expect(openedRequest.httpBody == body)
        #expect(openedRequest.value(forHTTPHeaderField: "X-Popup-Token") == "popup-token")
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func recoverableTerminalWindowPreservesBrowserAdaptersForReattachment() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let support = BrowserWebExtensionSupport()
        let previousHost = appDelegate.browserWebExtensionHost
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        appDelegate.browserWebExtensionHost = support
        BrowserAvailabilitySettings.setDisabled(false)
        let adapter = try #require(support.openNormalBrowserWindow(
            requestedTabs: [(nil, nil), (nil, nil)],
            shouldFocus: false
        ))
        let originalWindow = try #require(adapter.hostWindow)
        let context = try #require(appDelegate.contextForMainTerminalWindow(originalWindow))
        let workspace = try #require(context.tabManager.selectedWorkspace)
        let paneID = try #require(workspace.bonsplitController.allPaneIds.first)
        _ = try #require(workspace.newTerminalSurface(inPane: paneID, focus: false))
        let browserPanelIDs = workspace.panels.values.compactMap { ($0 as? BrowserPanel)?.id }
        let initiallyActivePanelID = try #require(support.activePanelID(in: originalWindow))
        let restoredPanelID = try #require(browserPanelIDs.first { $0 != initiallyActivePanelID })
        support.noteActivated(panelID: restoredPanelID)
        let replacementWindow = NSWindow()
        var didCloseOriginalWindow = false
        defer {
            if !didCloseOriginalWindow {
                _ = appDelegate.closeMainWindow(windowId: context.windowId, recordHistory: false)
            }
            context.tabManager.discardBrowserWebExtensionWindowOwnership()
            workspace.teardownAllPanels()
            appDelegate.forgetRecoverableMainWindowRoute(windowId: context.windowId)
            replacementWindow.close()
            appDelegate.browserWebExtensionHost = previousHost
            BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled)
        }

        didCloseOriginalWindow = appDelegate.closeMainWindow(windowId: context.windowId, recordHistory: false)
        #expect(didCloseOriginalWindow)
        #expect(browserPanelIDs.allSatisfy { support.tabAdapters[$0] != nil })

        _ = context.tabManager.setOwningWindow(replacementWindow)

        #expect(browserPanelIDs.allSatisfy { support.tabAdapters[$0] != nil })
        #expect(support.windowAdapter(for: restoredPanelID)?.hostWindow === replacementWindow)
        #expect(support.activePanelID(in: replacementWindow) == restoredPanelID)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func implicitTabCreationUsesFocusedTerminalOnlyWindow() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let support = BrowserWebExtensionSupport()
        let firstManager = TabManager(browserWebExtensionHost: support)
        let secondManager = TabManager(browserWebExtensionHost: support)
        let firstWorkspace = try #require(firstManager.selectedWorkspace)
        let secondWorkspace = try #require(secondManager.selectedWorkspace)
        let firstPaneID = try #require(firstWorkspace.bonsplitController.allPaneIds.first)
        let firstBrowser = try #require(firstWorkspace.newBrowserSurface(inPane: firstPaneID, focus: false))
        let firstWindow = NSWindow()
        let secondWindow = NSWindow()
        let firstWindowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: firstManager,
            window: firstWindow
        )
        let secondWindowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: secondManager,
            window: secondWindow
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: firstWindowID)
            appDelegate.unregisterMainWindowContextForTesting(windowId: secondWindowID)
            firstWorkspace.teardownAllPanels()
            secondWorkspace.teardownAllPanels()
            firstWindow.close()
            secondWindow.close()
        }

        NSApp.activate()
        firstWindow.orderFront(nil)
        firstWindow.makeKey()
        support.noteWindowBecameKey(firstWindow)
        support.noteActivated(panelID: firstBrowser.id)
        #expect(support.activePanelID == firstBrowser.id)

        secondWindow.orderFront(nil)
        secondWindow.makeKey()
        support.noteWindowBecameKey(secondWindow)
        #expect(support.activePanelID == nil)

        let openedAdapter = support.openBrowserTab(
            url: nil,
            shouldActivate: false,
            webViewConfiguration: nil
        )

        #expect(openedAdapter?.panel?.workspaceId == secondWorkspace.id)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func closingActiveBrowserWaitsForSoleSiblingSelection() {
        let support = BrowserWebExtensionSupport()
        let firstPanel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let secondPanel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let window = NSWindow()
        let contentView = NSView()
        window.contentView = contentView
        contentView.addSubview(firstPanel.webView)
        contentView.addSubview(secondPanel.webView)
        defer {
            support.unregister(panelID: secondPanel.id)
            firstPanel.close()
            secondPanel.close()
            window.close()
        }

        support.register(panel: firstPanel)
        support.register(panel: secondPanel)
        support.noteActivated(panelID: firstPanel.id)
        support.unregister(panelID: firstPanel.id)

        #expect(support.activePanelID(in: window) == nil)
        support.noteActivated(panelID: secondPanel.id)
        #expect(support.activePanelID(in: window) == secondPanel.id)
        #expect(support.isPanelActiveInWindow(secondPanel.id))
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func recoverableRouteDiscardsOwnershipAfterManagerDeallocation() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let support = BrowserWebExtensionSupport()
        var tabManager: TabManager? = TabManager(browserWebExtensionHost: support)
        let workspace = try #require(tabManager?.selectedWorkspace)
        let paneID = try #require(workspace.bonsplitController.allPaneIds.first)
        _ = try #require(workspace.newTerminalSurface(inPane: paneID, focus: false))
        let windowID = UUID()
        let window = NSWindow()
        appDelegate.rememberRecoverableMainWindowRoute(
            windowId: windowID,
            tabManager: try #require(tabManager),
            window: window
        )
        let route = try #require(appDelegate.recoverableMainWindowRoute(windowId: windowID))
        let panel = try #require(workspace.newBrowserSurface(inPane: paneID, focus: false))
        defer {
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowID)
            workspace.teardownAllPanels()
            window.close()
        }

        tabManager = nil
        #expect(route.tabManager == nil)
        #expect(support.tabAdapters[panel.id] != nil)

        route.discardBrowserWebExtensionWindowOwnership()

        #expect(support.tabAdapters[panel.id] == nil)
        #expect(!support.openTabNotificationPanelIDs.contains(panel.id))
    }

    @MainActor
    @Test
    func configuredCmuxShortcutTakesPriorityOverExtensionCommand() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let action = KeyboardShortcutSettings.Action.openBrowser
        let hadPersistedShortcut = UserDefaults.standard.object(forKey: action.defaultsKey) != nil
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            if hadPersistedShortcut {
                KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
        }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "L",
            charactersIgnoringModifiers: "l",
            isARepeat: false,
            keyCode: 37
        ))

        KeyboardShortcutSettings.setShortcut(action.defaultShortcut, for: action)
        #expect(!appDelegate.shouldOfferBrowserWebExtensionCommand(event))

        KeyboardShortcutSettings.setShortcut(.unbound, for: action)
        #expect(appDelegate.shouldOfferBrowserWebExtensionCommand(event))

        let plainTypingEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))
        #expect(!appDelegate.shouldOfferBrowserWebExtensionCommand(plainTypingEvent))
    }

    @MainActor
    @Test
    func browserFocusModeOffersExtensionCommandDespiteConfiguredShortcut() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let action = KeyboardShortcutSettings.Action.openBrowser
        let hadPersistedShortcut = UserDefaults.standard.object(forKey: action.defaultsKey) != nil
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            if hadPersistedShortcut {
                KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
        }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "L",
            charactersIgnoringModifiers: "l",
            isARepeat: false,
            keyCode: 37
        ))

        // With the default ⌘⇧L Open Browser binding, the extension command is
        // declined outside focus mode but offered inside it, where the app-level
        // monitor has already suspended configured cmux shortcuts.
        KeyboardShortcutSettings.setShortcut(action.defaultShortcut, for: action)
        #expect(!appDelegate.shouldOfferBrowserWebExtensionCommand(event, browserFocusModeActive: false))
        #expect(appDelegate.shouldOfferBrowserWebExtensionCommand(event, browserFocusModeActive: true))

        // Focus mode does not turn plain typing into extension commands.
        let plainTypingEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))
        #expect(!appDelegate.shouldOfferBrowserWebExtensionCommand(plainTypingEvent, browserFocusModeActive: true))
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func unchangedMetadataDoesNotInvalidateExtensionActions() async throws {
        let support = BrowserWebExtensionSupport()
        let panel = BrowserPanel(workspaceId: UUID(), browserWebExtensionHost: support)
        support.register(panel: panel)
        defer {
            support.unregister(panelID: panel.id)
            panel.close()
        }
        let invalidation = try #require(support.actionSnapshotInvalidationsByPanelID[panel.id])
        let initialRevision = invalidation.revision

        support.noteTabMetadataChanged(panelID: panel.id)
        await Task.yield()
        await Task.yield()

        #expect(invalidation.revision == initialRevision)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func sameExtensionLinkOpensSiblingTabWithOwningContext() throws {
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let appDelegate = try #require(AppDelegate.shared)
        let previousTabManager = appDelegate.tabManager
        let extensionURL = try #require(URL(string: "webkit-extension://cmux-test/options.html"))
        let siblingURL = try #require(URL(string: "webkit-extension://cmux-test/vault.html"))
        let host = BrowserWebExtensionReviewTestHost(extensionHost: extensionURL.host)
        let tabManager = TabManager(browserWebExtensionHost: host)
        appDelegate.tabManager = tabManager
        defer { appDelegate.tabManager = previousTabManager }

        let workspace = try #require(tabManager.selectedWorkspace)
        defer { workspace.teardownAllPanels() }
        let paneID = try #require(workspace.bonsplitController.allPaneIds.first)
        let sourcePanel = try #require(workspace.newBrowserSurface(
            inPane: paneID,
            url: extensionURL,
            focus: false
        ))
        #expect(sourcePanel.webExtensionPageContextIdentifier == host.contextIdentifier)

        sourcePanel.openLinkInNewTab(url: siblingURL)

        let siblingPanel = try #require(
            workspace.panels.values
                .compactMap { $0 as? BrowserPanel }
                .first { $0.id != sourcePanel.id }
        )
        #expect(siblingPanel.webExtensionPageContextIdentifier == host.contextIdentifier)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func extensionPagePanelLookupMatchesTheOwningContextOnly() throws {
        let extensionURL = try #require(URL(string: "webkit-extension://cmux-test/options.html"))
        let host = BrowserWebExtensionReviewTestHost(extensionHost: extensionURL.host)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: extensionURL,
            renderInitialNavigation: false,
            browserWebExtensionHost: host
        )
        let support = BrowserWebExtensionSupport()
        support.register(panel: panel)
        defer {
            support.unregister(panelID: panel.id)
            panel.close()
        }

        #expect(
            support.extensionPagePanels(usingContextIdentifier: host.contextIdentifier).map(\.id) == [panel.id]
        )
        #expect(
            support.extensionPagePanels(usingContextIdentifier: ObjectIdentifier(NSObject())).isEmpty
        )
    }
}
