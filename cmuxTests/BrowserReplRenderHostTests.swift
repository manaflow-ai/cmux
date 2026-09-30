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

    @Test func visibleDrivenTabStaysInItsPane() throws {
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
        panel.noteWebViewVisibility(true, reason: "test.visible")

        // The user works in another window: the pane still shows the tab, so
        // it must keep rendering there instead of going blank.
        let other = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 200, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        other.makeKeyAndOrderFront(nil)
        defer { other.orderOut(nil) }

        let sessionID = "render-host-test-\(UUID().uuidString)"
        defer { BrowserReplTabAttachments.shared.detach(sessionID: sessionID) }
        BrowserReplTabAttachments.shared.attach(panel: panel, sessionID: sessionID) { _, _ in }
        BrowserReplTabAttachments.shared.attachment(for: panel.id)?.keepRendering()

        #expect(webView.cmuxBrowserViewportAttachmentSuperview === paneHost)
        #expect(webView.window === window)
        #expect(visibleRenderWindows().isEmpty)
    }
}
