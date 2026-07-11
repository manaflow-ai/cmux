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
