import AppKit
import CmuxBrowser
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserWindowPortalRegistryNotificationTests {
    /// Counts explicit flushes even when AppKit has no dirty layout to apply.
    private final class CountingContentView: NSView {
        var layoutFlushCount = 0

        override func layoutSubtreeIfNeeded() {
            layoutFlushCount += 1
            super.layoutSubtreeIfNeeded()
        }
    }

    /// Supplies visibility to the workspace's window selection for the isolated
    /// fixture without depending on the test runner's active display state.
    private final class VisibleLayoutWindow: NSWindow {
        override var isVisible: Bool { true }
    }

    private final class LayoutCallbackView: NSView {
        var onLayout: (() -> Void)?

        override func layout() {
            super.layout()
            onLayout?()
        }
    }

    private final class LayoutSubtreeCallbackWebView: WKWebView {
        var onLayoutSubtreeIfNeeded: (() -> Void)?

        override func layoutSubtreeIfNeeded() {
            onLayoutSubtreeIfNeeded?()
            super.layoutSubtreeIfNeeded()
        }
    }

    private final class InspectorLayoutResetWebView: WKWebView {
        var onEnterInWindow: (() -> Void)?
        private(set) var enterInWindowCount = 0

        @objc(_enterInWindow)
        func unitTestEnterInWindow() {
            enterInWindowCount += 1
            onEnterInWindow?()
        }
    }

    private final class WKInspectorLayoutProbeView: NSView {}

    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func advanceAnimations() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func waitForNextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func hasOmnibarSuggestionsOverlay(in view: NSView) -> Bool {
        view.subviews.contains {
            String(describing: type(of: $0)).contains("OmnibarSuggestionsHostingView")
        }
    }

    @Test func registryDoesNotNotifyForUnchangedPortalVisibility() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let contentView = try #require(window.contentView)

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        contentView.addSubview(anchor)
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration(), host: CmuxWebViewAppHost())

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .browserPortalRegistryDidChange,
            object: webView,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        var presentabilityCount = 0
        let presentabilityObserver = NotificationCenter.default.addObserver(
            forName: .browserPortalDidBecomePresentable,
            object: webView,
            queue: nil
        ) { _ in
            presentabilityCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            NotificationCenter.default.removeObserver(presentabilityObserver)
            BrowserWindowPortalRegistry.detach(webView: webView)
        }

        // Start hidden so the first visible transition exercises the
        // presentability notification contract explicitly. A freshly created
        // slot is already unhidden at the AppKit level and therefore has no
        // hidden-to-visible transition to report.
        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: false)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        advanceAnimations()
        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: true, zPriority: 0)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        advanceAnimations()
        let baselineNotificationCount = notificationCount
        #expect(baselineNotificationCount == 2)
        #expect(presentabilityCount >= 1)
        #expect(BrowserWindowPortalRegistry.isPresented(webView))

        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: true, zPriority: 0)
        #expect(
            notificationCount == baselineNotificationCount,
            "Reapplying an unchanged portal visibility snapshot should not wake Workspace layout follow-up"
        )

        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: false, zPriority: 0)
        #expect(notificationCount == baselineNotificationCount + 1)
        #expect(!BrowserWindowPortalRegistry.isPresented(webView))

        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: false, zPriority: 0)
        #expect(
            notificationCount == baselineNotificationCount + 1,
            "Repeated hidden-state updates should not post duplicate registry-change notifications"
        )

        let slot = try #require(
            webView.cmuxBrowserViewportAttachmentSuperview as? WindowBrowserSlotView
        )
        #expect(!slot.isHidden)

        BrowserWindowPortalRegistry.hide(webView: webView, source: "unitTest")
        advanceAnimations()
        #expect(slot.isHidden)
        #expect(
            notificationCount == baselineNotificationCount + 2,
            "A hidden visibility state whose slot still needs presentation sync should notify exactly once"
        )

        BrowserWindowPortalRegistry.hide(webView: webView, source: "unitTest")
        advanceAnimations()
        #expect(
            notificationCount == baselineNotificationCount + 2,
            "A repeated hide after state and presentation are already hidden should not notify"
        )
    }

    /// A split-zoom retry flushes its host window without touching peers.
    @Test func browserSplitZoomRetriesFlushOnlyOwningWindow() async throws {
        let contentView = CountingContentView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = VisibleLayoutWindow(
            contentRect: contentView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()

        let unrelatedContentView = CountingContentView(frame: contentView.frame)
        let unrelatedWindow = VisibleLayoutWindow(
            contentRect: unrelatedContentView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        unrelatedWindow.contentView = unrelatedContentView
        defer { unrelatedWindow.orderOut(nil) }
        unrelatedWindow.orderFrontRegardless()
        #expect(NSApp.windows.contains { $0 === unrelatedWindow })

        let manager = TabManager()
        manager.window = window
        let workspace = try #require(manager.selectedWorkspace)
        defer { workspace.setPortalRenderingEnabled(false, reason: "test.cleanup") }
        let browserID = try #require(manager.openBrowser(inWorkspace: workspace.id, preferSplitRight: true))
        let browser = try #require(workspace.browserPanel(for: browserID))
        defer { BrowserWindowPortalRegistry.detach(webView: browser.webView) }

        // Use the product's zoom entry point. Only the browser is visible after
        // zoom, so terminal geometry converges on the first attempt. Its anchor
        // is deliberately unattached, leaving a real browser retry outstanding.
        #expect(browser.portalAnchorView.window == nil)
        #expect(workspace.toggleSplitZoom(panelId: browserID))
        #expect(workspace.bonsplitController.zoomedPaneId == workspace.paneId(forPanelId: browserID))
        contentView.layoutFlushCount = 0
        unrelatedContentView.layoutFlushCount = 0

        for _ in 0..<8 where contentView.layoutFlushCount < 2 {
            await waitForNextMainTurn()
        }
        #expect(
            contentView.layoutFlushCount >= 2,
            "The geometry pass and the later browser-only retry must each flush the owner"
        )
        #expect(
            unrelatedContentView.layoutFlushCount == 0,
            "Workspace retries must not flush an unrelated visible window"
        )
    }

    /// A browser visibility retry still flushes after terminal geometry settles.
    @Test func browserVisibilityRetryAfterGeometryPassFlushesOwningWindow() async throws {
        let contentView = CountingContentView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = VisibleLayoutWindow(
            contentRect: contentView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()

        let manager = TabManager()
        manager.window = window
        let workspace = try #require(manager.selectedWorkspace)
        let initialTerminalID = try #require(workspace.focusedPanelId)
        let browserID = try #require(manager.openBrowser(inWorkspace: workspace.id, preferSplitRight: true))
        let browser = try #require(workspace.browserPanel(for: browserID))
        #expect(workspace.closePanel(initialTerminalID, force: true))
        #expect(workspace.panels[initialTerminalID] == nil)
        defer {
            workspace.setPortalRenderingEnabled(false, reason: "test.cleanup")
            BrowserWindowPortalRegistry.detach(webView: browser.webView)
        }

        // Reset any setup follow-up, then enter through the geometry-only path.
        // The browser is the only rendered panel, so geometry converges while
        // its unattached anchor keeps browser visibility pending. That pending
        // browser retry must trigger a second scoped flush.
        workspace.setPortalRenderingEnabled(false, reason: "test.reset")
        contentView.layoutFlushCount = 0
        workspace.setPortalRenderingEnabled(true, reason: "test.geometryOnly")

        for _ in 0..<8 where contentView.layoutFlushCount < 2 {
            await waitForNextMainTurn()
        }
        #expect(
            contentView.layoutFlushCount >= 2,
            "A browser visibility retry after geometry convergence must flush its owner"
        )
    }

    @Test func portalRefreshDefersWebKitLayoutUntilOuterLayoutCompletes() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let contentView = try #require(window.contentView)

        let anchor = LayoutCallbackView(
            frame: NSRect(x: 24, y: 24, width: 360, height: 220)
        )
        contentView.addSubview(anchor)
        let webView = LayoutSubtreeCallbackWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        defer { BrowserWindowPortalRegistry.detach(webView: webView) }

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        advanceAnimations()

        var isRefreshingFromAnchorLayout = false
        var anchorLayoutCount = 0
        var webKitLayoutFlushCount = 0
        var webKitLayoutFlushesDuringAnchorLayout = 0
        webView.onLayoutSubtreeIfNeeded = {
            webKitLayoutFlushCount += 1
            if isRefreshingFromAnchorLayout {
                webKitLayoutFlushesDuringAnchorLayout += 1
            }
        }
        anchor.onLayout = {
            anchorLayoutCount += 1
            isRefreshingFromAnchorLayout = true
            defer { isRefreshingFromAnchorLayout = false }
            BrowserWindowPortalRegistry.refresh(webView: webView, reason: "unitTestOuterLayout")
        }
        anchor.setFrameSize(NSSize(width: 320, height: 190))
        anchor.needsLayout = true
        anchor.layoutSubtreeIfNeeded()
        anchor.onLayout = nil

        #expect(anchorLayoutCount == 1, "The test must execute the refresh from the anchor's layout stack")
        #expect(
            webKitLayoutFlushesDuringAnchorLayout == 0,
            "Restored browser geometry must not synchronously lay out WebKit while AppKit is already laying out the anchor"
        )

        await waitForNextMainTurn()
        await waitForNextMainTurn()
        #expect(
            webKitLayoutFlushCount > 0,
            "The deferred portal refresh must still lay out WebKit after the anchor callback returns"
        )
    }

    @Test func portalAnchorResynchronizesAfterAutoLayoutCorrectsReparentedGeometry() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let contentView = try #require(window.contentView)

        let firstHost = NSView(frame: NSRect(x: 24, y: 24, width: 220, height: 140))
        let replacementHost = NSView(frame: NSRect(x: 300, y: 64, width: 320, height: 230))
        contentView.addSubview(firstHost)
        contentView.addSubview(replacementHost)

        let anchor = BrowserPortalAnchorView(frame: firstHost.bounds)
        anchor.translatesAutoresizingMaskIntoConstraints = false
        firstHost.addSubview(anchor)
        let firstHostConstraints = [
            anchor.topAnchor.constraint(equalTo: firstHost.topAnchor),
            anchor.bottomAnchor.constraint(equalTo: firstHost.bottomAnchor),
            anchor.leadingAnchor.constraint(equalTo: firstHost.leadingAnchor),
            anchor.trailingAnchor.constraint(equalTo: firstHost.trailingAnchor),
        ]
        NSLayoutConstraint.activate(firstHostConstraints)
        firstHost.layoutSubtreeIfNeeded()

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration(), host: CmuxWebViewAppHost())
        defer { BrowserWindowPortalRegistry.detach(webView: webView) }
        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        await waitForNextMainTurn()
        await waitForNextMainTurn()

        let initialAnchorFrame = anchor.convert(anchor.bounds, to: nil)
        let initialSnapshot = try #require(BrowserWindowPortalRegistry.debugSnapshot(for: webView))
        #expect(abs(initialSnapshot.frameInWindow.width - initialAnchorFrame.width) <= 0.5)
        #expect(abs(initialSnapshot.frameInWindow.height - initialAnchorFrame.height) <= 0.5)

        NSLayoutConstraint.deactivate(firstHostConstraints)
        anchor.removeFromSuperview()
        replacementHost.addSubview(anchor)
        NSLayoutConstraint.activate([
            anchor.topAnchor.constraint(equalTo: replacementHost.topAnchor),
            anchor.bottomAnchor.constraint(equalTo: replacementHost.bottomAnchor),
            anchor.leadingAnchor.constraint(equalTo: replacementHost.leadingAnchor),
            anchor.trailingAnchor.constraint(equalTo: replacementHost.trailingAnchor),
        ])
        replacementHost.needsLayout = true

        #expect(
            abs(anchor.frame.width - replacementHost.bounds.width) > 1,
            "The regression requires the reused anchor to retain its prior size until Auto Layout runs"
        )
        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        let staleSnapshot = try #require(BrowserWindowPortalRegistry.debugSnapshot(for: webView))
        #expect(abs(staleSnapshot.frameInWindow.width - anchor.frame.width) <= 0.5)

        replacementHost.layoutSubtreeIfNeeded()
        let correctedAnchorFrame = anchor.convert(anchor.bounds, to: nil)
        #expect(abs(correctedAnchorFrame.width - replacementHost.bounds.width) <= 0.5)
        #expect(abs(correctedAnchorFrame.height - replacementHost.bounds.height) <= 0.5)

        await waitForNextMainTurn()
        await waitForNextMainTurn()

        let synchronizedSnapshot = try #require(
            BrowserWindowPortalRegistry.debugSnapshot(for: webView)
        )
        #expect(
            abs(synchronizedSnapshot.frameInWindow.minX - correctedAnchorFrame.minX) <= 0.5 &&
                abs(synchronizedSnapshot.frameInWindow.minY - correctedAnchorFrame.minY) <= 0.5 &&
                abs(synchronizedSnapshot.frameInWindow.width - correctedAnchorFrame.width) <= 0.5 &&
                abs(synchronizedSnapshot.frameInWindow.height - correctedAnchorFrame.height) <= 0.5,
            "The portal must adopt the anchor's corrected Auto Layout geometry without an unrelated host update"
        )
    }

    @Test func renderingStateReattachReappliesStoredHostedInspectorDivider() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let contentView = try #require(window.contentView)

        let anchor = NSView(frame: NSRect(x: 24, y: 24, width: 360, height: 220))
        contentView.addSubview(anchor)
        let webView = InspectorLayoutResetWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        defer { BrowserWindowPortalRegistry.detach(webView: webView) }

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        advanceAnimations()

        let slot = try #require(
            webView.cmuxBrowserViewportAttachmentSuperview as? WindowBrowserSlotView
        )
        let preferredInspectorWidth: CGFloat = 132
        let lifecycleResetInspectorWidth: CGFloat = 76
        let pageHeight = slot.bounds.height

        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.height]
        webView.frame = NSRect(
            x: 0,
            y: 0,
            width: slot.bounds.width - preferredInspectorWidth,
            height: pageHeight
        )
        let inspectorContainer = NSView(
            frame: NSRect(
                x: webView.frame.maxX,
                y: 0,
                width: preferredInspectorWidth,
                height: pageHeight
            )
        )
        inspectorContainer.autoresizingMask = [.minXMargin, .height]
        let inspectorView = WKInspectorLayoutProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        slot.addSubview(inspectorContainer)
        slot.recordPreferredHostedInspectorWidth(
            preferredInspectorWidth,
            containerBounds: slot.bounds
        )

        webView.onEnterInWindow = { [weak webView, weak inspectorContainer] in
            guard let webView, let inspectorContainer, let slot = webView.superview else { return }
            webView.frame = NSRect(
                x: 0,
                y: 0,
                width: slot.bounds.width - lifecycleResetInspectorWidth,
                height: slot.bounds.height
            )
            inspectorContainer.frame = NSRect(
                x: webView.frame.maxX,
                y: 0,
                width: lifecycleResetInspectorWidth,
                height: slot.bounds.height
            )
        }

        webView.browserPortalNotifyHidden(reason: "unitTestInspectorLayoutReset")
        #expect(webView.browserPortalRequiresRenderingStateReattach)

        BrowserWindowPortalRegistry.refresh(
            webView: webView,
            reason: "unitTestInspectorLayoutReset"
        )
        await waitForNextMainTurn()
        await waitForNextMainTurn()

        #expect(
            webView.enterInWindowCount > 0,
            "The test must execute the WebKit lifecycle callback that resets the inspector split"
        )
        #expect(
            abs(inspectorContainer.frame.width - preferredInspectorWidth) <= 0.5,
            "The stored inspector width must win after WebKit's deferred lifecycle reattach"
        )
        #expect(
            abs(webView.frame.width - (slot.bounds.width - preferredInspectorWidth)) <= 0.5,
            "Reapplying the inspector width must restore the matching page width"
        )
    }

    @Test func visiblePortalPreservesExternalRenderHostUntilRestore() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let contentView = try #require(window.contentView)
        let anchor = NSView(frame: NSRect(x: 24, y: 24, width: 360, height: 220))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration(), host: CmuxWebViewAppHost())
        defer { BrowserWindowPortalRegistry.detach(webView: webView) }
        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)

        let portalHost = try #require(webView.cmuxBrowserViewportAttachmentSuperview)
        let renderHost = BrowserOffscreenRenderHost(
            webView: webView,
            viewportSize: NSSize(width: 393, height: 852)
        )
        defer { renderHost.restore() }
        let offscreenHost = try #require(webView.cmuxBrowserViewportAttachmentSuperview)

        #expect(webView.cmuxBrowserViewportExternalRenderHostIsActive)
        #expect(offscreenHost !== portalHost)
        #expect(
            webView.cmuxBrowserViewportAttachmentWindow?.identifier?.rawValue ==
                "cmux.browserVisualAutomationRender"
        )

        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        #expect(webView.cmuxBrowserViewportAttachmentSuperview === offscreenHost)

        renderHost.resize(to: NSSize(width: 852, height: 393))
        #expect(offscreenHost.bounds.size == NSSize(width: 852, height: 393))

        #expect(renderHost.restore())
        #expect(!webView.cmuxBrowserViewportExternalRenderHostIsActive)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        #expect(webView.cmuxBrowserViewportAttachmentSuperview === portalHost)
    }

    @Test func browserPanelCloseDetachesPortalAndDismissesSuggestionsWhileCallbacksRetainPanel() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let contentView = try #require(window.contentView)
        let anchor = NSView(frame: NSRect(x: 24, y: 24, width: 360, height: 220))
        contentView.addSubview(anchor)

        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            isRemoteWorkspace: false
        )
        let webView = panel.webView
        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)

        var retainedPanel: BrowserPanel? = panel
        BrowserWindowPortalRegistry.updateSearchOverlay(
            for: webView,
            configuration: BrowserPortalSearchOverlayConfiguration(
                panelId: panel.id,
                searchState: BrowserSearchState(),
                focusRequestGeneration: 0,
                canApplyFocusRequest: { _ in retainedPanel != nil },
                onNext: { _ = retainedPanel?.id },
                onPrevious: { _ = retainedPanel?.id },
                onClose: { _ = retainedPanel?.id },
                onFieldDidFocus: { _ = retainedPanel?.id }
            )
        )
        let item = OmnibarSuggestion.search(engineName: "Google", query: "news")
        BrowserWindowPortalRegistry.updateOmnibarSuggestions(
            for: webView,
            configuration: BrowserPortalOmnibarSuggestionsConfiguration(
                panelId: panel.id,
                popupFrame: CGRect(x: 16, y: 16, width: 220, height: OmnibarSuggestionsView.popupHeight(for: [item])),
                colorScheme: .dark,
                engineName: "Google",
                items: [item],
                selectedIndex: 0,
                isLoadingRemoteSuggestions: false,
                searchSuggestionsEnabled: true,
                onCommit: { _ in _ = retainedPanel?.id },
                onHighlight: { _ in _ = retainedPanel?.id }
            )
        )

        let slot = try #require(
            webView.cmuxBrowserViewportAttachmentSuperview as? WindowBrowserSlotView
        )
        #expect(BrowserWindowPortalRegistry.debugSnapshot(for: webView) != nil)
        #expect(slot.browserPortalTestSearchOverlayView != nil)
        #expect(hasOmnibarSuggestionsOverlay(in: slot))

        panel.close()

        #expect(BrowserWindowPortalRegistry.debugSnapshot(for: webView) == nil)
        #expect(slot.superview == nil)
        #expect(slot.browserPortalTestSearchOverlayView == nil)
        #expect(!hasOmnibarSuggestionsOverlay(in: slot))
        retainedPanel = nil
    }
}
