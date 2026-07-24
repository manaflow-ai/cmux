import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
final class GlobalSearchInputOwnershipTests {
    private let originalSettingsFileStore: KeyboardShortcutSettingsFileStore

    init() {
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-global-search-input-ownership-\(UUID().uuidString).json")
                .path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()
    }

    deinit {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        KeyboardShortcutSettings.resetAll()
    }

    @Test func browserFocusModeOwnsGlobalSearchShortcut() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let harness = try makeBrowserHarness(appDelegate: appDelegate)
        defer { closeWindow(harness.window, appDelegate: appDelegate) }

        #expect(
            harness.panel.setBrowserFocusModeActive(
                true,
                reason: "globalSearchInputOwnershipTest",
                focusWebView: false
            )
        )
        let event = try makeKeyDownEvent(
            key: "f",
            modifiers: [.command, .option],
            keyCode: 3,
            windowNumber: harness.window.windowNumber
        )

        let handled = appDelegate.debugHandleCustomShortcut(event: event)
        if handled {
            appDelegate.toggleGlobalSearchPalette()
        }

        #expect(!handled, "Browser focus mode must get the shortcut before app-scoped Global Search")
#else
        Issue.record("Global Search input-ownership routing requires a DEBUG build")
#endif
    }

    @Test func markedTextOwnsOptionOnlyGlobalSearchShortcut() throws {
#if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        let harness = try makeBrowserHarness(appDelegate: appDelegate)
        defer { closeWindow(harness.window, appDelegate: appDelegate) }

        let field = OmnibarNativeTextField(frame: NSRect(x: 8, y: 8, width: 240, height: 24))
        field.identifier = browserOmnibarTextFieldIdentifier
        field.panelId = harness.panel.id
        field.stringValue = "かな"
        (harness.window.contentView?.superview ?? harness.window.contentView)?.addSubview(field)
        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: harness.panel.id)
        defer {
            BrowserOmnibarNativeFieldRegistry.shared.unregister(field, panelId: harness.panel.id)
            field.removeFromSuperview()
        }

        #expect(harness.window.makeFirstResponder(field))
        let fieldEditor = try #require(field.currentEditor() as? NSTextView)
        fieldEditor.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(fieldEditor.hasMarkedText())
        NotificationCenter.default.post(name: .browserDidFocusAddressBar, object: harness.panel.id)

        let shortcut = StoredShortcut(
            key: "q",
            command: false,
            shift: false,
            option: true,
            control: false
        )
        KeyboardShortcutSettings.setShortcut(shortcut, for: .globalSearch)
        let event = try makeKeyDownEvent(
            key: "q",
            characters: "@",
            modifiers: [.option],
            keyCode: 12,
            windowNumber: harness.window.windowNumber
        )

        let handled = appDelegate.debugHandleCustomShortcut(event: event)
        if handled {
            appDelegate.toggleGlobalSearchPalette()
        }

        #expect(!handled, "An Option-only Global Search binding must yield to active IME marked text")
#else
        Issue.record("Global Search input-ownership routing requires a DEBUG build")
#endif
    }

    private func makeBrowserHarness(
        appDelegate: AppDelegate
    ) throws -> (window: NSWindow, panel: BrowserPanel, webView: CmuxWebView) {
        let windowId = appDelegate.createMainWindow()
        guard let window = window(withId: windowId),
              let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let browserURL = URL(string: "data:text/html;base64,PGh0bWw+PGJvZHk+Zm9jdXM8L2JvZHk+PC9odG1sPg=="),
              let browserPanelId = manager.openBrowser(
                  inWorkspace: workspace.id,
                  url: browserURL,
                  preferSplitRight: true
              ),
              let browserPanel = manager.selectedWorkspace?.browserPanel(for: browserPanelId)
                  ?? workspace.browserPanel(for: browserPanelId),
              let webView = browserPanel.webView as? CmuxWebView else {
            if let window = window(withId: windowId) {
                closeWindow(window, appDelegate: appDelegate)
            }
            throw TestHarnessError.browserHarnessUnavailable
        }

        workspace.focusPanel(browserPanel.id)
        if webView.cmuxBrowserViewportAttachmentSuperview == nil,
           let contentView = window.contentView {
            let presentationView = webView.cmuxBrowserViewportPresentationView
            contentView.addSubview(presentationView)
            webView.cmuxApplyBrowserViewportLayout(in: contentView.bounds)
        }
        window.makeKeyAndOrderFront(nil)
        guard window.makeFirstResponder(webView) else {
            closeWindow(window, appDelegate: appDelegate)
            throw TestHarnessError.browserFocusUnavailable
        }
        return (window, browserPanel, webView)
    }

    private func makeKeyDownEvent(
        key: String,
        characters: String? = nil,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: characters ?? key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            throw TestHarnessError.eventUnavailable
        }
        return event
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func closeWindow(_ window: NSWindow, appDelegate: AppDelegate) {
#if DEBUG
        let originalConfirmationHandler = appDelegate.debugCloseMainWindowConfirmationHandler
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = originalConfirmationHandler }
#endif
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.05))
    }

    private enum TestHarnessError: Error {
        case browserHarnessUnavailable
        case browserFocusUnavailable
        case eventUnavailable
    }
}
