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

    /// Render windows other suites in this test process left on screen; only
    /// a render window that appears during a test belongs to it.
    private let preexistingRenderWindows: Set<ObjectIdentifier>

    init() {
        preexistingRenderWindows = Set(
            NSApp.windows
                .filter { $0.identifier?.rawValue == Self.renderWindowIdentifier && $0.isVisible }
                .map(ObjectIdentifier.init)
        )
    }

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
        NSApp.windows.filter {
            $0.identifier?.rawValue == Self.renderWindowIdentifier && $0.isVisible
                && !preexistingRenderWindows.contains(ObjectIdentifier($0))
        }
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

    /// A workspace transition can hide the portal hierarchy before the
    /// panel's logical visibility flag is updated. Native input must follow
    /// the live hierarchy into the render host instead of targeting that
    /// hidden WebView.
    @Test func shownTabHiddenInHierarchyUsesRenderHostForInput() throws {
        let (window, _, panel, paneHost) = try makePane(key: true)
        defer { window.orderOut(nil) }
        defer { BrowserWindowPortalRegistry.detach(webView: panel.webView) }
        let sessionID = "render-host-test-\(UUID().uuidString)"
        defer { BrowserReplTabAttachments.shared.detach(sessionID: sessionID) }
        let attachment = BrowserReplTabAttachments.shared.attach(panel: panel, sessionID: sessionID) { _, _ in }

        // Keep the logical pane state shown, but model the hidden ancestor
        // left behind while its workspace is inactive.
        paneHost.isHidden = true
        defer { paneHost.isHidden = false }
        #expect(panel.isWebViewVisibleInPane)
        #expect(panel.webView.isHiddenOrHasHiddenAncestor)

        attachment.keepRendering()

        #expect(attachment.isInRenderWindow)
        #expect(attachment.isMirroringPane)
        #expect(panel.webView.window?.identifier?.rawValue == Self.renderWindowIdentifier)
        #expect(!panel.webView.isHiddenOrHasHiddenAncestor)
        #expect(panel.isWebViewVisibleInPane)
    }

    /// A key-window transition must not release a render host while the
    /// original pane hierarchy is still hidden. Once the portal reveals that
    /// hierarchy, its presentability signal releases the host without another
    /// pane visibility-state transition.
    @Test func renderHostStaysWhenPaneHidesBeforeWindowBecomesKey() async throws {
        let (window, anchor, panel, paneHost) = try makePane(key: false)
        defer { window.orderOut(nil) }
        defer { BrowserWindowPortalRegistry.detach(webView: panel.webView) }
        let sessionID = "render-host-test-\(UUID().uuidString)"
        defer { BrowserReplTabAttachments.shared.detach(sessionID: sessionID) }
        let attachment = BrowserReplTabAttachments.shared.attach(panel: panel, sessionID: sessionID) { _, _ in }

        #expect(attachment.isInRenderWindow)
        // Hide the portal's anchor as well as its slot. A full portal sync is
        // queued by makePane; keeping both hidden makes that pending pass part
        // of the same inactive-workspace transition instead of allowing it to
        // reveal the slot while this test waits for the key notification.
        anchor.isHidden = true
        paneHost.isHidden = true
        defer {
            anchor.isHidden = false
            paneHost.isHidden = false
        }
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)

        window.reportsKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await Task.yield()

        #expect(attachment.isInRenderWindow)
        #expect(panel.webView.window?.identifier?.rawValue == Self.renderWindowIdentifier)
        #expect(attachment.isMirroringPane)

        anchor.isHidden = false
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        await Task.yield()

        #expect(!attachment.isInRenderWindow)
        #expect(panel.webView.window === window)
    }

    @Test func shownTabInNonKeyWindowLeavesAMirrorAndReturnsWhenKey() async throws {
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
        // The key observer crosses into the MainActor explicitly because AppKit
        // notification callbacks do not carry a Swift executor token.
        await Task.yield()
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        #expect(panel.webView.cmuxBrowserViewportAttachmentSuperview === paneHost)
        #expect(panel.webView.window === window)
        #expect(!attachment.isMirroringPane)
        #expect(visibleRenderWindows().isEmpty)
    }

    /// Input to a tab that just moved into the render window must wait until
    /// WebKit has applied the new window, visibility and focus state, or
    /// the page sees keys while it is not yet focused.
    @Test func movedTabIsFocusedOnceRenderingSettles() async throws {
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
        panel.noteWebViewVisibility(false, reason: "test.hidden")
        let sessionID = "render-host-test-\(UUID().uuidString)"
        defer { BrowserReplTabAttachments.shared.detach(sessionID: sessionID) }
        let attachment = BrowserReplTabAttachments.shared.attach(panel: panel, sessionID: sessionID) { _, _ in }

        await attachment.renderingSettled()
        let state = try await webView.evaluateJavaScript("document.visibilityState + ':' + document.hasFocus()") as? String
        #expect(state == "visible:true")
    }
}
