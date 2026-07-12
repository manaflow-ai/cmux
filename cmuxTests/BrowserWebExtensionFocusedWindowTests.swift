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
        support.noteActivated(panelID: secondPanel.id)
        #expect(support.activePanelID == secondPanel.id)

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
}
