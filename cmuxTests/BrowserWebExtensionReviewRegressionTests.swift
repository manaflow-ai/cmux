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

@MainActor
private final class BrowserWebExtensionReviewTestHost: BrowserWebExtensionHosting {
    private let extensionHost: String?
    private let contextToken = NSObject()
    private let configuration = WKWebViewConfiguration()

    init(extensionHost: String?) {
        self.extensionHost = extensionHost
    }

    var contextIdentifier: ObjectIdentifier {
        ObjectIdentifier(contextToken)
    }

    func attach(to configuration: WKWebViewConfiguration) {}

    func webViewConfiguration(forNavigatingTo url: URL) -> BrowserWebExtensionNavigationConfiguration? {
        guard url.scheme?.lowercased() == "webkit-extension",
              url.host == extensionHost else { return nil }
        return BrowserWebExtensionNavigationConfiguration(
            contextIdentifier: contextIdentifier,
            webViewConfiguration: configuration
        )
    }

    func register(panel: BrowserPanel) {}
    func unregister(panelID: UUID) {}
    func noteActivated(panelID: UUID) {}
    func noteTabMetadataChanged(panelID: UUID) {}
    func performCommand(for event: NSEvent) -> Bool { false }
}
