import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Hidden browser panes are discarded by their visibility report, so a pane must
/// only count as visible while one of its views is in a window. SwiftUI can build
/// a browser view that never reaches a window, then dismantle it; a visible report
/// from that view used to leave a hidden pane marked visible, so it was never
/// discarded (issue #15069).
@MainActor
@Suite(.serialized) struct BrowserPanelWindowVisibilityTests {
    @Test func portalHostOutsideAWindowDoesNotMarkThePanelVisible() async {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        #expect(!panel.isWebViewVisibleInUI)

        let hostingView = NSHostingView(
            rootView: WebViewRepresentable(
                panel: panel,
                paneId: PaneID(id: UUID()),
                shouldAttachWebView: true,
                useLocalInlineHosting: false,
                shouldFocusWebView: false,
                isPanelFocused: true,
                portalZPriority: 0,
                paneDropZone: nil,
                paneOwnershipOverride: true,
                searchOverlay: nil,
                designComposer: nil,
                omnibarSuggestions: nil,
                paneTopChromeHeight: 0
            )
        )
        let detachedRoot = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        hostingView.frame = detachedRoot.bounds
        detachedRoot.addSubview(hostingView)
        defer { hostingView.removeFromSuperview() }

        #expect(
            await settle(hostingView, until: { findHostContainerView(in: hostingView) != nil }),
            "Expected the representable to build its host."
        )
        await settle(hostingView)
        #expect(
            !panel.isWebViewVisibleInUI,
            "A portal host that is not in a window must not mark the panel visible."
        )

        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.contentView?.addSubview(hostingView)
        #expect(
            await settle(hostingView, until: { panel.isWebViewVisibleInUI }),
            "The portal host must mark the panel visible once it enters a window."
        )
    }

    @Test func panelViewOutsideAWindowDoesNotMarkThePanelVisible() async {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        #expect(!panel.isWebViewVisibleInUI)

        let hostingView = NSHostingView(
            rootView: BrowserPanelWindowVisibilityHarness(panel: panel, paneID: PaneID())
        )
        let detachedRoot = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        hostingView.frame = detachedRoot.bounds
        detachedRoot.addSubview(hostingView)
        defer { hostingView.removeFromSuperview() }

        #expect(
            await settle(hostingView, until: { findWindowPresenceView(in: hostingView) != nil }),
            "Expected the browser panel to build its window-presence probe."
        )
        await settle(hostingView)
        #expect(
            !panel.isWebViewVisibleInUI,
            "A browser panel view that is not in a window must not mark the panel visible."
        )

        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.contentView?.addSubview(hostingView)
        #expect(
            await settle(hostingView, until: { panel.isWebViewVisibleInUI }),
            "The browser panel view must mark the panel visible once it enters a window."
        )
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Lays the hosting view out and lets the work that layout scheduled run
    /// before the caller asserts: SwiftUI appearance callbacks on the run loop,
    /// and main-actor tasks such as portal lifecycle and window-entry reports.
    /// Use it once the views exist and before asserting that a report did not
    /// happen, which has no completion to wait on.
    private func settle(_ hostingView: NSView) async {
        for _ in 0..<5 {
            await settlePass(hostingView)
        }
    }

    /// Settles until `condition` holds, with a real deadline so a regression
    /// fails the expectation instead of hanging.
    private func settle(_ hostingView: NSView, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            await settlePass(hostingView)
        }
        return condition()
    }

    /// The test body is itself a main-actor job, so the nested run loop can't
    /// run other main-actor jobs; yielding lets the ones already queued run.
    private func settlePass(_ hostingView: NSView) async {
        layOut(hostingView)
        await Task.yield()
    }

    /// Lays the view out and turns the run loop once for SwiftUI's updates.
    private func layOut(_ hostingView: NSView) {
        hostingView.window?.displayIfNeeded()
        hostingView.superview?.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }

    private func findWindowPresenceView(in root: NSView) -> BrowserPanelWindowPresenceView? {
        if let probe = root as? BrowserPanelWindowPresenceView {
            return probe
        }
        for subview in root.subviews {
            if let probe = findWindowPresenceView(in: subview) {
                return probe
            }
        }
        return nil
    }

    private func findHostContainerView(in root: NSView) -> WebViewRepresentable.HostContainerView? {
        if let host = root as? WebViewRepresentable.HostContainerView {
            return host
        }
        for subview in root.subviews {
            if let host = findHostContainerView(in: subview) {
                return host
            }
        }
        return nil
    }
}

@MainActor
private struct BrowserPanelWindowVisibilityHarness: View {
    let panel: BrowserPanel
    let paneID: PaneID

    var body: some View {
        PanelContentView(
            panel: panel,
            workspaceId: panel.workspaceId,
            paneId: paneID,
            isFocused: true,
            isSelectedInPane: true,
            isVisibleInUI: true,
            allowsPointerInput: true,
            portalPriority: 1,
            isSplit: false,
            appearance: PanelAppearance(
                backgroundColor: .windowBackgroundColor,
                foregroundColor: .labelColor,
                dividerColor: .clear,
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0,
                usesClearContentBackground: false
            ),
            windowAppearance: .rightSidebarPanelViewTestDefault,
            customSidebarTabManager: nil,
            hasUnreadNotification: false,
            terminalAgentContext: "",
            paneOwnershipOverride: true,
            onFocus: {},
            onRequestPanelFocus: {},
            onResumeAgentHibernation: {},
            onAutoResumeAgentHibernation: {},
            onTriggerFlash: {},
            onRequestDeferredBrowserMaterialization: {}
        )
    }
}
