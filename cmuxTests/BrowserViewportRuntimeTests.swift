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
struct BrowserViewportRuntimeTests {
    @Test
    func replacementNavigationBarrierPrecedesSynchronousPolicyInterruption() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        let webView = panel.webView
        let delegate = try #require(panel.navigationDelegate)
        // Obtain real WebKit navigation identities, but drive the configured
        // callbacks explicitly so the policy-interruption ordering is deterministic.
        webView.navigationDelegate = nil
        let original = try #require(webView.loadHTMLString("<p>original</p>", baseURL: nil))
        let replacement = try #require(webView.loadHTMLString("<p>replacement</p>", baseURL: nil))
        let coordinator = panel.automationNavigationCoordinator
        let ticket = coordinator.begin(instanceID: panel.webViewInstanceID)
        coordinator.didStart(ticket, navigationID: ObjectIdentifier(original))

        delegate.willReplaceNavigationForUserAgentPolicy?(webView, original)
        _ = delegate.didInterruptProvisionalNavigationByPolicy?(webView, original)
        delegate.didReplaceNavigationForUserAgentPolicy?(webView, original, replacement)
        delegate.didCommit?(webView, replacement)

        #expect(await coordinator.wait(for: ticket) == .committed)
    }

    @Test
    func dockConfigurationDoesNotReparentInspectorDuringDividerDrag() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let contentView = try #require(window.contentView)
        let host = WebViewRepresentable.HostContainerView(frame: contentView.bounds)
        contentView.addSubview(host)
        let slot = host.ensureLocalInlineSlotView()
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        let inspector = DockConfigurationProbeWebView(
            frame: NSRect(x: 500, y: 0, width: 300, height: 500)
        )
        slot.addSubview(page)
        slot.addSubview(inspector)
        host.pinHostedWebView(page, in: slot)
        host.setHostedInspectorFrontendWebView(inspector)
        host.viewDidMoveToWindow()
        contentView.layoutSubtreeIfNeeded()
        #expect(host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded())
        let container = try #require(page.superview)
        #expect(container !== slot)

        // Wait for a real dock query scheduled by the host's layout, then
        // deliver its completion inside the mouse-down/up interval.
        var queries = inspector.dockQueries.makeAsyncIterator()
        await queries.next()
        let point = host.convert(NSPoint(x: inspector.frame.minX + 2, y: 250), to: nil)
        func mouseEvent(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: point.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        host.mouseDown(with: try mouseEvent(.leftMouseDown, x: point.x))
        inspector.completeDockQueries(with: "bottom")
        #expect(page.superview === container)
        #expect(inspector.superview === container)

        let initialWidth = inspector.frame.width
        host.mouseDragged(with: try mouseEvent(.leftMouseDragged, x: point.x - 30))
        #expect(inspector.frame.width > initialWidth)
        #expect(page.superview === container)
        host.mouseUp(with: try mouseEvent(.leftMouseUp, x: point.x - 30))

        #expect(page.superview === slot)
        #expect(inspector.superview === slot)

        // A layout pass after mouse-up must not immediately promote the inline
        // split back into the side dock after WebKit reported a bottom dock.
        host.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var remainedInline = true
        while remainedInline, ContinuousClock.now < deadline {
            remainedInline = page.superview === slot && inspector.superview === slot
            if remainedInline {
                await AppKitTestEventPump().drain()
            }
        }
        #expect(remainedInline)
        #expect(page.superview === slot)
        #expect(inspector.superview === slot)
    }

    private final class DockConfigurationProbeWebView: WKWebView {
        let dockQueries: AsyncStream<Void>
        private let queryContinuation: AsyncStream<Void>.Continuation
        private var completions: [@MainActor @Sendable (Any?, (any Error)?) -> Void] = []

        init(frame: NSRect) {
            (dockQueries, queryContinuation) = AsyncStream<Void>.makeStream()
            super.init(frame: frame, configuration: WKWebViewConfiguration())
        }

        required init?(coder: NSCoder) { nil }

        override func evaluateJavaScript(
            _ javaScriptString: String,
            completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil
        ) {
            if javaScriptString == "typeof WI === 'undefined' ? null : WI.dockConfiguration",
               let completionHandler {
                completions.append(completionHandler)
                queryContinuation.yield(())
            } else {
                completionHandler?(nil, nil)
            }
        }

        func completeDockQueries(with configuration: String) {
            let pending = completions
            completions.removeAll()
            for completion in pending {
                completion(configuration, nil)
            }
        }
    }

    @Test
    func frameworkLayoutCallbackCanEnterViewportHostThroughMainThreadDispatch() async {
        let host = BrowserViewportHostView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 240)
        )
        let hostPointer = Unmanaged.passUnretained(host).toOpaque()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                let host = Unmanaged<BrowserViewportHostView>
                    .fromOpaque(hostPointer)
                    .takeUnretainedValue()
                host.performSelector(
                    onMainThread: #selector(NSView.layout),
                    with: nil,
                    waitUntilDone: true
                )
                continuation.resume()
            }
        }

        #expect(host.frame.size == NSSize(width: 320, height: 240))
    }

    @Test
    func frameworkGeometryNotificationEntersMainActorAfterCallbackReturns() async {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let invalidator = PortalSplitDividerCacheInvalidator()
        var callbackCount = 0
        let (callbacks, continuation) = AsyncStream<Void>.makeStream()
        invalidator.observe(geometryViews: [view], structureViews: []) {
            callbackCount += 1
            continuation.yield(())
        }
        defer { invalidator.invalidate() }

        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: view)
        #expect(!invalidator.structureIsCurrent())
        #expect(callbackCount == 0)

        var iterator = callbacks.makeAsyncIterator()
        await iterator.next()
        #expect(callbackCount == 1)
    }

    @Test
    func frameworkObserversDoNotRetainInvalidatorAfterTeardown() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        weak var weakInvalidator: PortalSplitDividerCacheInvalidator?
        do {
            let invalidator = PortalSplitDividerCacheInvalidator()
            weakInvalidator = invalidator
            invalidator.observe(geometryViews: [view], structureViews: []) {}
        }

        #expect(weakInvalidator == nil)
    }

    @Test
    func nativePortalLayoutDoesNotRewriteStableWebViewGeometry() {
        let slot = WindowBrowserSlotView(
            frame: NSRect(x: 0, y: 0, width: 380, height: 610)
        )
        let webView = BrowserViewportPropertyWriteProbeWebView(
            frame: slot.bounds,
            configuration: WKWebViewConfiguration()
        )
        defer { webView.removeFromSuperview() }

        slot.addSubview(webView)
        slot.pinHostedWebView(webView)
        #expect(webView.cmuxBrowserViewportPresentationView === webView)
        #expect(webView.frame == slot.bounds)
        #expect(webView.autoresizingMask == [.width, .height])

        webView.beginRecordingViewportPropertyWrites()
        for _ in 0..<10 {
            slot.needsLayout = true
            slot.layoutSubtreeIfNeeded()
        }

        #expect(webView.redundantViewportPropertyWriteCount == 0)
        #expect(webView.frame == slot.bounds)
        #expect(webView.bounds == slot.bounds)
    }

    @Test
    func emulatedPortalLayoutTracksSlotBoundsChanges() throws {
        let slot = WindowBrowserSlotView(
            frame: NSRect(x: 0, y: 0, width: 380, height: 610)
        )
        let webView = CmuxWebView(frame: slot.bounds, configuration: WKWebViewConfiguration(), host: CmuxWebViewAppHost())
        let viewportHost = BrowserViewportHostView(frame: slot.bounds)
        let viewportModel = BrowserViewportModel()
        defer {
            webView.removeFromSuperview()
            viewportHost.removeFromSuperview()
        }

        webView.browserViewportModel = viewportModel
        viewportModel.setViewport(try #require(BrowserViewport(width: 1_280, height: 720)))
        viewportHost.installWebView(webView)
        slot.addSubview(viewportHost)
        slot.pinHostedWebView(webView)

        #expect(webView.cmuxBrowserViewportUsesHost)
        #expect(webView.cmuxBrowserViewportPresentationView === viewportHost)

        slot.setFrameSize(NSSize(width: 720, height: 420))
        slot.needsLayout = true
        slot.layoutSubtreeIfNeeded()

        let expectedLayout = try #require(webView.cmuxBrowserViewportLayout(in: slot.bounds))
        #expect(expectedLayout.mode == .emulated)
        #expect(viewportHost.matches(expectedLayout))
    }

    @Test
    func nativeViewportActivatesPresentationHostOnlyWhileEmulationIsRequested() throws {
        let panel = BrowserPanel(workspaceId: UUID(), initialURL: URL(string: "about:blank")!)
        let webView = panel.webView
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 610))
        let lowerSibling = NSView(frame: .zero)
        let upperSibling = NSView(frame: .zero)
        defer {
            webView.cmuxBrowserViewportPresentationView.removeFromSuperview()
            panel.close()
        }

        #expect(webView.cmuxBrowserViewportPresentationView === webView)
        container.addSubview(lowerSibling)
        container.addSubview(webView, positioned: .above, relativeTo: lowerSibling)
        container.addSubview(upperSibling, positioned: .above, relativeTo: webView)
        #expect(webView.superview === container)
        #expect(panel.viewportHostView.superview == nil)
        #expect(container.subviews[1] === webView)

        let viewport = try #require(BrowserViewport(width: 1_280, height: 720))
        let emulatedLayout = try panel.setAutomationViewport(viewport).get()

        #expect(emulatedLayout.mode == .emulated)
        #expect(webView.cmuxBrowserViewportPresentationView === panel.viewportHostView)
        #expect(webView.superview === panel.viewportHostView)
        #expect(panel.viewportHostView.superview === container)
        #expect(container.subviews[1] === panel.viewportHostView)

        let nativeLayout = try panel.setAutomationViewport(nil).get()

        #expect(nativeLayout.mode == .native)
        #expect(webView.cmuxBrowserViewportPresentationView === webView)
        #expect(webView.superview === container)
        #expect(panel.viewportHostView.superview == nil)
        #expect(container.subviews[1] === webView)
        #expect(webView.cmuxBrowserViewportLayoutMatches(container.bounds))

        panel.scheduleBrowserViewportHostRestoration(reason: "nativeRegressionTest")
        #expect(panel.browserViewportHostRestorationTask == nil)
        #expect(!panel.browserViewportHostRestorationPending)
        #expect(webView.superview === container)
        #expect(panel.viewportHostView.superview == nil)
    }

    @Test
    func emulatedViewportDrivesDOMZoomScreenshotsAndInputGeometry() async throws {
        let paneFrame = NSRect(x: 0, y: 0, width: 380, height: 610)
        let window = NSWindow(
            contentRect: paneFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let pane = NSView(frame: paneFrame)
        let webView = CmuxWebView(frame: pane.bounds, configuration: WKWebViewConfiguration(), host: CmuxWebViewAppHost())
        let viewportHost = BrowserViewportHostView(frame: pane.bounds)
        let viewportModel = BrowserViewportModel()
        let loadDelegate = BrowserViewportRuntimeLoadDelegate()
        webView.browserViewportModel = viewportModel
        webView.navigationDelegate = loadDelegate
        viewportHost.installWebView(webView)
        pane.addSubview(webView)
        window.contentView = pane
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            viewportHost.removeFromSuperview()
            window.close()
        }

        try await loadDelegate.load(
            """
            <!doctype html>
            <html>
              <head>
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <style>
                  #responsive { display: none; }
                  @media (min-width: 1000px) { #responsive { display: block; } }
                </style>
              </head>
              <body>
                <div id="responsive">wide</div>
                <button id="target" style="position: fixed; left: 1080px; top: 580px; width: 140px; height: 100px">
                  target
                </button>
              </body>
            </html>
            """,
            in: webView
        )

        let viewport = try #require(BrowserViewport(width: 1_280, height: 720))
        viewportModel.setViewport(viewport)
        #expect(webView.cmuxRestoreIntoBrowserViewportHostAfterExternalGeometryIfSafe())
        let layout = try #require(webView.cmuxApplyBrowserViewportLayout(in: pane.bounds))
        #expect(layout.mode == .emulated)

        let metrics = try await runtimeMetrics(in: webView)

        #expect(metrics["width"] as? Int == 1_280)
        #expect(metrics["height"] as? Int == 720)
        #expect(metrics["wide"] as? Bool == true)
        #expect(metrics["responsiveDisplay"] as? String == "block")

        // The real browser portal forces AppKit layout/display passes after a viewport RPC.
        // Keep that exact pressure here: autoresizing must not collapse the raw WKWebView
        // back to the aspect-fitted presentation frame.
        viewportHost.needsLayout = true
        pane.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(!viewportHost.autoresizesSubviews)
        #expect(webView.autoresizingMask.isEmpty)
        assertSizeApproximatelyEquals(webView.frame.size, NSSize(width: 1_280, height: 720))
        assertSizeApproximatelyEquals(webView.bounds.size, NSSize(width: 1_280, height: 720))
        let postPortalLayoutMetrics = try await runtimeMetrics(in: webView)
        #expect(postPortalLayoutMetrics["width"] as? Int == 1_280)
        #expect(postPortalLayoutMetrics["height"] as? Int == 720)
        #expect(postPortalLayoutMetrics["wide"] as? Bool == true)

        assertViewportCorners(layout: layout, host: viewportHost, pane: pane)
        assertTargetHitTestsThroughScaledHost(webView: webView, host: viewportHost, pane: pane)

        for pageZoom in [1.1, 1.25, 0.8, 2.0] {
            webView.pageZoom = pageZoom
            let zoomedLayout = try #require(webView.cmuxApplyBrowserViewportLayout(in: pane.bounds))
            let zoomedMetrics = try await runtimeMetrics(in: webView)

            #expect(zoomedMetrics["width"] as? Int == 1_280)
            #expect(zoomedMetrics["height"] as? Int == 720)
            assertSizeApproximatelyEquals(viewportHost.bounds.size, zoomedLayout.webViewBounds.size)
            assertSizeApproximatelyEquals(webView.bounds.size, zoomedLayout.webViewBounds.size)
            assertViewportCorners(layout: zoomedLayout, host: viewportHost, pane: pane)
            assertTargetHitTestsThroughScaledHost(webView: webView, host: viewportHost, pane: pane)
        }

        let fractionalScaledViewport = try #require(BrowserViewport(width: 375, height: 812))
        viewportModel.setViewport(fractionalScaledViewport)
        webView.pageZoom = 1.1
        _ = try #require(webView.cmuxApplyBrowserViewportLayout(in: pane.bounds))
        let fractionalScaledMetrics = try await runtimeMetrics(in: webView)
        #expect(fractionalScaledMetrics["width"] as? Int == 375)
        #expect(fractionalScaledMetrics["height"] as? Int == 812)

        let nearWholePointZoom: CGFloat = (412.0 + 0.000_000_5) / 375.0
        webView.pageZoom = nearWholePointZoom
        _ = try #require(webView.cmuxApplyBrowserViewportLayout(in: pane.bounds))
        let nearWholePointMetrics = try await runtimeMetrics(in: webView)
        #expect(nearWholePointMetrics["width"] as? Int == 375)
        #expect(nearWholePointMetrics["height"] as? Int == 812)

        viewportModel.setViewport(viewport)
        webView.pageZoom = 1
        _ = try #require(webView.cmuxApplyBrowserViewportLayout(in: pane.bounds))

        let screenshot = try await BrowserScreenshotWebViewSnapshotter.captureVisibleViewport(
            from: webView
        )
        let screenshotRepresentation = try #require(screenshot.representations.first)
        #expect(screenshotRepresentation.pixelsWide == 1_280)
        #expect(screenshotRepresentation.pixelsHigh == 720)

        let visibleHostFrame = viewportHost.frame
        let visibleHostBounds = viewportHost.bounds
        try await BrowserScreenshotWebViewSnapshotter.withOffscreenRenderHost(
            webView,
            viewportSize: NSSize(width: 640, height: 360),
            expectedURL: nil
        ) {
            #expect(viewportHost.superview !== pane)
            #expect(webView.cmuxBrowserViewportPresentationView === viewportHost)
            let offscreenMetrics = try await immediateRuntimeMetrics(in: webView)
            #expect(offscreenMetrics["width"] as? Int == 1_280)
            #expect(offscreenMetrics["height"] as? Int == 720)

            let offscreenScreenshot = try await BrowserScreenshotWebViewSnapshotter
                .captureVisibleViewport(from: webView)
            let representation = try #require(offscreenScreenshot.representations.first)
            #expect(representation.pixelsWide == 1_280)
            #expect(representation.pixelsHigh == 720)
        }
        #expect(viewportHost.superview === pane)
        #expect(viewportHost.frame == visibleHostFrame)
        #expect(viewportHost.bounds == visibleHostBounds)
        let restoredMetrics = try await runtimeMetrics(in: webView)
        #expect(restoredMetrics["width"] as? Int == 1_280)
        #expect(restoredMetrics["height"] as? Int == 720)

        viewportModel.setViewport(nil)
        let nativeLayout = try #require(webView.cmuxBrowserViewportLayout(in: pane.bounds))
        #expect(viewportHost.deactivateWebView(using: nativeLayout))
        let nativeMetrics = try await runtimeMetrics(in: webView)
        #expect(nativeLayout.mode == .native)
        #expect(webView.superview === pane)
        #expect(viewportHost.superview == nil)
        #expect(nativeMetrics["width"] as? Int == Int(nativeLayout.bounds.width))
        #expect(nativeMetrics["height"] as? Int == Int(nativeLayout.bounds.height))
    }

    @Test
    func presentationRootTracksExternalWebKitOwnershipAndRestoresSafely() throws {
        let originalContainer = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 610))
        let externalContainer = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let webView = CmuxWebView(frame: originalContainer.bounds, configuration: WKWebViewConfiguration(), host: CmuxWebViewAppHost())
        let viewportHost = BrowserViewportHostView(frame: originalContainer.bounds)
        let viewportModel = BrowserViewportModel()
        let viewport = try #require(BrowserViewport(width: 1_280, height: 720))
        webView.browserViewportModel = viewportModel
        viewportModel.setViewport(viewport)
        viewportHost.installWebView(webView)
        originalContainer.addSubview(viewportHost)
        _ = try #require(webView.cmuxApplyBrowserViewportLayout(in: originalContainer.bounds))

        #expect(webView.cmuxBrowserViewportPresentationView === viewportHost)
        #expect(webView.cmuxBrowserViewportAttachmentSuperview === originalContainer)

        webView.removeFromSuperview()
        externalContainer.addSubview(webView)

        #expect(webView.cmuxBrowserViewportPresentationView === webView)
        #expect(webView.cmuxBrowserViewportAttachmentSuperview === externalContainer)

        let companion = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 100),
            configuration: WKWebViewConfiguration()
        )
        externalContainer.addSubview(companion)
        #expect(!webView.cmuxRestoreIntoBrowserViewportHostAfterExternalGeometryIfSafe())
        #expect(webView.superview === externalContainer)
        #expect(viewportHost.superview === originalContainer)

        companion.removeFromSuperview()
        #expect(webView.cmuxRestoreIntoBrowserViewportHostAfterExternalGeometryIfSafe())
        #expect(webView.superview === viewportHost)
        #expect(viewportHost.superview === externalContainer)
        #expect(webView.cmuxBrowserViewportPresentationView === viewportHost)
        #expect(webView.cmuxBrowserViewportAttachmentSuperview === externalContainer)
        #expect(webView.cmuxBrowserViewportLayoutMatches(externalContainer.bounds))

        webView.removeFromSuperview()
        #expect(webView.cmuxRestoreIntoBrowserViewportHostIfNeeded())
        #expect(webView.superview === viewportHost)
    }

    @Test
    func attachedInspectorResetUsesPresentationContainerGeometry() throws {
        let panel = BrowserPanel(workspaceId: UUID(), initialURL: URL(string: "about:blank")!)
        defer { panel.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 610))
        let presentationView = panel.webView.cmuxBrowserViewportPresentationView
        container.addSubview(presentationView)
        defer { presentationView.removeFromSuperview() }

        let viewport = try #require(BrowserViewport(width: 1_280, height: 720))
        let emulatedLayout = try panel.setAutomationViewport(viewport).get()
        #expect(emulatedLayout.mode == .emulated)
        let companion = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1_280, height: 220),
            configuration: WKWebViewConfiguration()
        )
        panel.viewportHostView.addSubview(companion)
        panel.webView.frame = NSRect(x: 0, y: 220, width: 1_280, height: 500)

        #expect(panel.resetAutomationViewportForAttachedBrowserInspector())
        #expect(panel.viewportModel.viewport == nil)
        #expect(panel.viewportHostView.frame == container.bounds)
        #expect(panel.viewportHostView.bounds == container.bounds)
        #expect(panel.webView.autoresizingMask == [.width, .height])
    }

    @Test
    func mobileStreamViewportPersistsOffscreenAcrossRotationAndRestoresPresentation() throws {
        let panel = BrowserPanel(workspaceId: UUID(), initialURL: URL(string: "about:blank")!)
        defer { panel.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let presentationView = panel.webView.cmuxBrowserViewportPresentationView
        container.addSubview(presentationView)

        let previousViewport = try #require(BrowserViewport(width: 1_280, height: 720))
        _ = try panel.setAutomationViewport(previousViewport).get()
        let previousPresentationView = panel.webView.cmuxBrowserViewportPresentationView
        #expect(previousPresentationView.superview === container)

        #expect(panel.applyMobileStreamViewport(width: 393, height: 852, scale: 3))
        let offscreenHost = try #require(
            panel.webView.cmuxBrowserViewportAttachmentSuperview
        )
        #expect(panel.mobileBrowserStreamRenderHost != nil)
        #expect(panel.viewportModel.requestedViewport == BrowserViewport(width: 393, height: 852))
        #expect(previousPresentationView.superview === offscreenHost)
        #expect(
            panel.webView.cmuxBrowserViewportAttachmentWindow?.identifier?.rawValue ==
                "cmux.browserVisualAutomationRender"
        )

        #expect(panel.applyMobileStreamViewport(width: 852, height: 393, scale: 3))
        #expect(panel.webView.cmuxBrowserViewportAttachmentSuperview === offscreenHost)
        #expect(offscreenHost.bounds.size == NSSize(width: 852, height: 393))
        #expect(panel.viewportModel.requestedViewport == BrowserViewport(width: 852, height: 393))

        panel.clearMobileStreamViewport()

        #expect(panel.mobileBrowserStreamRenderHost == nil)
        #expect(panel.mobileBrowserStreamViewport == nil)
        #expect(panel.viewportModel.requestedViewport == previousViewport)
        #expect(panel.webView.cmuxBrowserViewportPresentationView === previousPresentationView)
        #expect(previousPresentationView.superview === container)
    }

    @Test
    func mobileStreamViewportFallsBackToOnscreenCaptureForAttachedInspector() {
        let panel = BrowserPanel(workspaceId: UUID(), initialURL: URL(string: "about:blank")!)
        defer { panel.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let presentationView = panel.webView.cmuxBrowserViewportPresentationView
        container.addSubview(presentationView)
        let inspectorCompanion = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 180),
            configuration: WKWebViewConfiguration()
        )
        container.addSubview(inspectorCompanion)

        #expect(panel.applyMobileStreamViewport(width: 393, height: 852, scale: 3))
        #expect(panel.mobileBrowserStreamRenderHost == nil)
        #expect(panel.viewportModel.requestedViewport == nil)
        #expect(panel.webView.cmuxBrowserViewportPresentationView.superview === container)
    }

    private func runtimeMetrics(in webView: WKWebView) async throws -> [String: Any] {
        // App-host tests can run behind XCTest's shielding window, where WebKit may
        // suppress requestAnimationFrame indefinitely. Yield briefly for viewport
        // propagation, then read synchronously observable runtime state.
        try await Task.sleep(for: .milliseconds(100))
        return try await immediateRuntimeMetrics(in: webView)
    }

    private func immediateRuntimeMetrics(in webView: WKWebView) async throws -> [String: Any] {
        let rawMetrics = try await webView.evaluateJavaScript(
            """
            ({
              width: window.innerWidth,
              height: window.innerHeight,
              wide: window.matchMedia('(min-width: 1000px)').matches,
              responsiveDisplay: getComputedStyle(document.getElementById('responsive')).display
            })
            """,
            contentWorld: .page
        )
        return try #require(rawMetrics as? [String: Any])
    }

    private func assertViewportCorners(
        layout: BrowserViewportLayout,
        host: BrowserViewportHostView,
        pane: NSView
    ) {
        let topLeft = host.convert(NSPoint(x: host.bounds.minX, y: host.bounds.minY), to: pane)
        let bottomRight = host.convert(NSPoint(x: host.bounds.maxX, y: host.bounds.maxY), to: pane)

        #expect(abs(topLeft.x - layout.frame.minX) < 0.5)
        #expect(abs(topLeft.y - layout.frame.maxY) < 0.5)
        #expect(abs(bottomRight.x - layout.frame.maxX) < 0.5)
        #expect(abs(bottomRight.y - layout.frame.minY) < 0.5)
    }

    private func assertSizeApproximatelyEquals(
        _ actual: CGSize,
        _ expected: CGSize,
        epsilon: CGFloat = 0.000_1
    ) {
        #expect(abs(actual.width - expected.width) < epsilon)
        #expect(abs(actual.height - expected.height) < epsilon)
    }

    private func assertTargetHitTestsThroughScaledHost(
        webView: WKWebView,
        host: BrowserViewportHostView,
        pane: NSView
    ) {
        let pageZoom = webView.pageZoom
        let targetCenterInWebView = NSPoint(x: 1_150 * pageZoom, y: 630 * pageZoom)
        let targetCenterInPane = webView.convert(targetCenterInWebView, to: pane)
        let hitView = pane.hitTest(targetCenterInPane)

        #expect(hitView != nil)
        #expect(hitView === webView || hitView?.isDescendant(of: webView) == true)
        #expect(host.frame.contains(targetCenterInPane))
    }
}

@MainActor
private final class BrowserViewportPropertyWriteProbeWebView: WKWebView {
    private(set) var redundantViewportPropertyWriteCount = 0
    private var recordsViewportPropertyWrites = false

    override var translatesAutoresizingMaskIntoConstraints: Bool {
        didSet {
            if recordsViewportPropertyWrites,
               oldValue == translatesAutoresizingMaskIntoConstraints {
                redundantViewportPropertyWriteCount += 1
            }
        }
    }

    override var autoresizingMask: NSView.AutoresizingMask {
        didSet {
            if recordsViewportPropertyWrites, oldValue == autoresizingMask {
                redundantViewportPropertyWriteCount += 1
            }
        }
    }

    func beginRecordingViewportPropertyWrites() {
        redundantViewportPropertyWriteCount = 0
        recordsViewportPropertyWrites = true
    }
}
