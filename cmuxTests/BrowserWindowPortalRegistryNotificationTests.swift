import AppKit
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
    private final class CountingContentView: NSView {
        var layoutPassCount = 0

        override func layout() {
            layoutPassCount += 1
            super.layout()
        }
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
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .browserPortalRegistryDidChange,
            object: webView,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            BrowserWindowPortalRegistry.detach(webView: webView)
        }

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        advanceAnimations()
        #expect(notificationCount == 1)

        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: true, zPriority: 0)
        #expect(
            notificationCount == 1,
            "Reapplying an unchanged portal visibility snapshot should not wake Workspace layout follow-up"
        )

        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: false, zPriority: 0)
        #expect(notificationCount == 2)

        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: false, zPriority: 0)
        #expect(
            notificationCount == 2,
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
            notificationCount == 3,
            "A hidden visibility state whose slot still needs presentation sync should notify exactly once"
        )

        BrowserWindowPortalRegistry.hide(webView: webView, source: "unitTest")
        advanceAnimations()
        #expect(
            notificationCount == 3,
            "A repeated hide after state and presentation are already hidden should not notify"
        )
    }

    @Test func unchangedPortalVisibilityDoesNotDriveWorkspaceLayoutFollowUp() throws {
        let contentView = CountingContentView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        contentView.layoutPassCount = 0

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        contentView.addSubview(anchor)
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        defer { BrowserWindowPortalRegistry.detach(webView: webView) }

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        advanceAnimations()

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelId))
        let layoutObserver = NotificationCenter.default.addObserver(
            forName: .browserPortalRegistryDidChange,
            object: webView,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                contentView.needsLayout = true
                workspace.debugBeginReparentFocusSuppressionForTesting(
                    panel.hostedView,
                    reason: "workspace.browserPortalLayoutHotpathTest"
                )
                workspace.debugAttemptEventDrivenLayoutFollowUpForTesting()
            }
        }
        defer { NotificationCenter.default.removeObserver(layoutObserver) }

        NotificationCenter.default.post(name: .browserPortalRegistryDidChange, object: webView)
        #expect(
            contentView.layoutPassCount == 1,
            "A browser portal registry notification should drive a Workspace layout follow-up pass"
        )

        let layoutCountBeforeNoOpBurst = contentView.layoutPassCount
        for _ in 0..<50 {
            BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: true, zPriority: 0)
        }
        advanceAnimations()
        #expect(
            contentView.layoutPassCount == layoutCountBeforeNoOpBurst,
            "Reapplying unchanged browser portal visibility snapshots must not force Workspace layout passes"
        )

        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: false, zPriority: 0)
        #expect(
            contentView.layoutPassCount == layoutCountBeforeNoOpBurst + 1,
            "A real browser portal visibility change should still wake Workspace layout follow-up"
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

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
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

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
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
