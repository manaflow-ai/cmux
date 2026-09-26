import AppKit
import Bonsplit
import SwiftUI
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserInlineHostAttachmentTests {
    @Test func deferredInlineHostAdoptsPreloadedBrowserWhenItJoinsWindow() throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }

        // Automation starts navigation in a hidden host before SwiftUI has
        // mounted the Canvas pane. Keep the page there until the new host has
        // a window; a detached replacement must not take a live page early.
        let preloadWindow = makeWindow(size: NSSize(width: 800, height: 600))
        preloadWindow.alphaValue = 0
        let preloadContent = try #require(preloadWindow.contentView)
        preloadContent.addSubview(panel.webView)
        panel.webView.frame = preloadContent.bounds
        defer { preloadWindow.close() }

        let representable = WebViewRepresentable(
            panel: panel,
            paneId: PaneID(),
            shouldAttachWebView: false,
            useLocalInlineHosting: true,
            shouldFocusWebView: false,
            isPanelFocused: false,
            portalZPriority: 0,
            paneDropZone: nil,
            paneOwnershipOverride: true,
            searchOverlay: nil,
            designComposer: nil,
            omnibarSuggestions: nil,
            paneTopChromeHeight: 0
        )
        let detachedRoot = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        let hosting = NSHostingView(rootView: representable)
        hosting.sizingOptions = []
        hosting.frame = detachedRoot.bounds
        hosting.autoresizingMask = [.width, .height]
        detachedRoot.addSubview(hosting)
        detachedRoot.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        let host = try #require(waitForHost(in: hosting), "The detached representable must be mounted")
        #expect(host.window == nil)
        #expect(panel.webView.superview === preloadContent)

        let visibleWindow = makeWindow(size: detachedRoot.bounds.size)
        defer {
            hosting.removeFromSuperview()
            visibleWindow.close()
        }
        let visibleContent = try #require(visibleWindow.contentView)
        visibleContent.addSubview(hosting)
        visibleWindow.orderFrontRegardless()
        visibleContent.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        // No rootView reassignment or unrelated panel change should be needed
        // to finish an attachment deferred solely for a missing window.
        #expect(waitUntil {
            host.window === visibleWindow &&
                panel.webView.isDescendant(of: host) &&
                panel.webView.window === visibleWindow &&
                abs(panel.webView.frame.width - host.bounds.width) < 1 &&
                abs(panel.webView.frame.height - host.bounds.height) < 1
        })
    }

    private func makeWindow(size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func waitForHost(
        in root: NSView,
        timeout: TimeInterval = 2
    ) -> WebViewRepresentable.HostContainerView? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let host = findHost(in: root) { return host }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return findHost(in: root)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    private func findHost(in root: NSView) -> WebViewRepresentable.HostContainerView? {
        if let host = root as? WebViewRepresentable.HostContainerView { return host }
        for child in root.subviews {
            if let host = findHost(in: child) { return host }
        }
        return nil
    }
}
