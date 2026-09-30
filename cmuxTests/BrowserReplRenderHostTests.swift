import AppKit
import CmuxBrowser
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Where a tab driven by a `cmux browser repl` session renders: in its pane
/// while a pane shows it, else in a render window nobody can see or click.
@MainActor
@Suite(.serialized)
struct BrowserReplRenderHostTests {
    private static let renderWindowIdentifier = "cmux.browserVisualAutomationRender"

    private func makeWindow() throws -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let contentView = try #require(window.contentView)
        let anchor = NSView(frame: NSRect(x: 24, y: 24, width: 360, height: 220))
        contentView.addSubview(anchor)
        return (window, anchor)
    }

    private func visibleRenderWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.identifier?.rawValue == Self.renderWindowIdentifier && $0.isVisible }
    }

    @Test func hiddenDrivenTabRendersOffEveryScreenAndReturnsToItsPane() throws {
        let (window, anchor) = try makeWindow()
        defer { window.orderOut(nil) }
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            isRemoteWorkspace: false
        )
        let webView = panel.webView
        defer { BrowserWindowPortalRegistry.detach(webView: webView) }
        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        let paneHost = try #require(webView.cmuxBrowserViewportAttachmentSuperview)

        // A background tab: no pane shows it, so a driving session moves it
        // into the render window.
        panel.noteWebViewVisibility(false, reason: "test.hidden")
        let sessionID = "render-host-test-\(UUID().uuidString)"
        defer { BrowserReplTabAttachments.shared.detach(sessionID: sessionID) }
        BrowserReplTabAttachments.shared.attach(panel: panel, sessionID: sessionID) { _, _ in }

        let renderWindow = try #require(webView.window)
        #expect(renderWindow.identifier?.rawValue == Self.renderWindowIdentifier)
        for screen in NSScreen.screens {
            #expect(
                !renderWindow.frame.intersects(screen.frame),
                "The render window must lie outside every screen, got \(renderWindow.frame) on \(screen.frame)"
            )
        }
        #expect(renderWindow.ignoresMouseEvents)
        #expect(renderWindow.level.rawValue <= NSWindow.Level.normal.rawValue)

        // The pane shows the tab: the web view comes back at once.
        panel.noteWebViewVisibility(true, reason: "test.visible")
        #expect(webView.cmuxBrowserViewportAttachmentSuperview === paneHost)
        #expect(webView.window === window)
        #expect(visibleRenderWindows().isEmpty)

        // Hidden again, then the session ends: the pane gets it back.
        panel.noteWebViewVisibility(false, reason: "test.hiddenAgain")
        BrowserReplTabAttachments.shared.attachment(for: panel.id)?.keepRendering()
        #expect(webView.window?.identifier?.rawValue == Self.renderWindowIdentifier)
        BrowserReplTabAttachments.shared.detach(sessionID: sessionID)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        #expect(webView.cmuxBrowserViewportAttachmentSuperview === paneHost)
        #expect(visibleRenderWindows().isEmpty)
    }

    /// A window whose key status the test controls; a test host app may not
    /// be active, and then no window is key.
    private final class KeyStatusWindow: NSWindow {
        var reportsKey = false
        override var isKeyWindow: Bool { reportsKey }
    }

    private func makePane(key: Bool) throws -> (KeyStatusWindow, NSView, BrowserPanel, NSView) {
        let window = KeyStatusWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.reportsKey = key
        window.orderFront(nil)
        window.displayIfNeeded()
        let contentView = try #require(window.contentView)
        let anchor = NSView(frame: NSRect(x: 24, y: 24, width: 360, height: 220))
        contentView.addSubview(anchor)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            isRemoteWorkspace: false
        )
        BrowserWindowPortalRegistry.bind(webView: panel.webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        let paneHost = try #require(panel.webView.cmuxBrowserViewportAttachmentSuperview)
        panel.noteWebViewVisibility(true, reason: "test.visible")
        return (window, anchor, panel, paneHost)
    }

    @Test func shownTabInKeyWindowStaysInItsPane() throws {
        let (window, _, panel, paneHost) = try makePane(key: true)
        defer { window.orderOut(nil) }
        defer { BrowserWindowPortalRegistry.detach(webView: panel.webView) }
        let sessionID = "render-host-test-\(UUID().uuidString)"
        defer { BrowserReplTabAttachments.shared.detach(sessionID: sessionID) }
        BrowserReplTabAttachments.shared.attach(panel: panel, sessionID: sessionID) { _, _ in }

        #expect(panel.webView.cmuxBrowserViewportAttachmentSuperview === paneHost)
        #expect(panel.webView.window === window)
        #expect(visibleRenderWindows().isEmpty)
    }

    @Test func shownTabInNonKeyWindowLeavesAMirrorAndReturnsWhenKey() throws {
        // The user works in another app: the page needs a key window for
        // focus and hover, and the pane must not go blank meanwhile.
        let (window, anchor, panel, paneHost) = try makePane(key: false)
        defer { window.orderOut(nil) }
        defer { BrowserWindowPortalRegistry.detach(webView: panel.webView) }
        let sessionID = "render-host-test-\(UUID().uuidString)"
        defer { BrowserReplTabAttachments.shared.detach(sessionID: sessionID) }
        BrowserReplTabAttachments.shared.attach(panel: panel, sessionID: sessionID) { _, _ in }
        let attachment = try #require(BrowserReplTabAttachments.shared.attachment(for: panel.id))

        #expect(panel.webView.window?.identifier?.rawValue == Self.renderWindowIdentifier)
        #expect(attachment.isMirroringPane)
        #expect(!paneHost.subviews.isEmpty, "A mirror stands in the pane")

        window.reportsKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        #expect(panel.webView.cmuxBrowserViewportAttachmentSuperview === paneHost)
        #expect(panel.webView.window === window)
        #expect(!attachment.isMirroringPane)
        #expect(visibleRenderWindows().isEmpty)
    }
}
