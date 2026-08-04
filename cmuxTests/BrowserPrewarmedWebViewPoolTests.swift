import AppKit
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Harness with all pool seams injected: the factory returns local webviews
/// backed by a non-persistent store, loads are recorded instead of hitting
/// the network, and the expiry sleep is swapped per test.
@MainActor
private final class PrewarmPoolHarness {
    let dataStore = WKWebsiteDataStore.nonPersistent()
    private(set) var madeWebViews: [CmuxWebView] = []
    private(set) var loadedRequests: [URLRequest] = []
    let pool: BrowserPrewarmedWebViewPool

    init(expirySleep: @escaping @Sendable (Duration) async throws -> Void = { _ in
        try await Task.sleep(for: .seconds(3600))
    }) {
        var recordWebView: (@MainActor (CmuxWebView) -> Void)!
        var recordRequest: (@MainActor (URLRequest) -> Void)!
        let dataStore = dataStore
        pool = BrowserPrewarmedWebViewPool(
            makeWebView: { _ in
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = dataStore
                let webView = CmuxWebView(frame: .zero, configuration: configuration)
                recordWebView(webView)
                return webView
            },
            startLoad: { _, request in
                recordRequest(request)
            },
            expirySleep: expirySleep
        )
        recordWebView = { [weak self] in self?.madeWebViews.append($0) }
        recordRequest = { [weak self] in self?.loadedRequests.append($0) }
    }
}

private let pricingURL = URL(string: "https://cmux.com/app-pricing?appearance=dark")!
private let otherURL = URL(string: "https://cmux.com/docs")!
private let profileID = UUID()

@MainActor
struct BrowserPrewarmedWebViewPoolTests {
    @Test func prewarmLoadsURLInHiddenHostedWebView() {
        let harness = PrewarmPoolHarness()
        harness.pool.prewarm(url: pricingURL, profileID: profileID)

        #expect(harness.madeWebViews.count == 1)
        #expect(harness.loadedRequests.map(\.url) == [pricingURL])
        #expect(harness.madeWebViews[0].window != nil)
        #expect(harness.madeWebViews[0].window?.isVisible == true)
        #expect(harness.pool.hasEntry(url: pricingURL, profileID: profileID))
        harness.pool.discard(reason: "test-teardown")
    }

    @Test func repeatPrewarmForSameURLIsANoOp() {
        let harness = PrewarmPoolHarness()
        harness.pool.prewarm(url: pricingURL, profileID: profileID)
        harness.pool.prewarm(url: pricingURL, profileID: profileID)

        #expect(harness.madeWebViews.count == 1)
        #expect(harness.loadedRequests.count == 1)
        harness.pool.discard(reason: "test-teardown")
    }

    @Test func prewarmForDifferentURLReplacesEntry() {
        let harness = PrewarmPoolHarness()
        harness.pool.prewarm(url: pricingURL, profileID: profileID)
        harness.pool.prewarm(url: otherURL, profileID: profileID)

        #expect(harness.madeWebViews.count == 2)
        #expect(!harness.pool.hasEntry(url: pricingURL, profileID: profileID))
        #expect(harness.pool.hasEntry(url: otherURL, profileID: profileID))
        // The replaced webview is fully torn down.
        #expect(harness.madeWebViews[0].window == nil)
        harness.pool.discard(reason: "test-teardown")
    }

    @Test func claimBeforeLoadFinishesReturnsNilAndConsumesEntry() {
        let harness = PrewarmPoolHarness()
        harness.pool.prewarm(url: pricingURL, profileID: profileID)

        let claimed = harness.pool.claim(
            url: pricingURL,
            profileID: profileID,
            websiteDataStore: harness.dataStore
        )

        #expect(claimed == nil)
        #expect(!harness.pool.hasEntry(url: pricingURL, profileID: profileID))
    }

    @Test func claimAfterFinishReturnsDetachedWebView() {
        let harness = PrewarmPoolHarness()
        harness.pool.prewarm(url: pricingURL, profileID: profileID)
        let webView = harness.madeWebViews[0]
        harness.pool.webView(webView, didFinish: nil)

        let claimed = harness.pool.claim(
            url: pricingURL,
            profileID: profileID,
            websiteDataStore: harness.dataStore
        )

        #expect(claimed === webView)
        #expect(claimed?.window == nil)
        #expect(claimed?.superview == nil)
        #expect(claimed?.navigationDelegate == nil)
        // The portal's first-attach refresh only fires the WebKit reattach
        // selectors for webviews marked hidden; without this the adopted view
        // keeps the prewarm-sized layer tree (#7554 dogfood round 1).
        #expect(claimed?.browserPortalRequiresRenderingStateReattach == true)
        #expect(!harness.pool.hasEntry(url: pricingURL, profileID: profileID))
    }

    @Test func claimForDifferentURLKeepsEntry() {
        let harness = PrewarmPoolHarness()
        harness.pool.prewarm(url: pricingURL, profileID: profileID)
        let webView = harness.madeWebViews[0]
        harness.pool.webView(webView, didFinish: nil)

        let mismatch = harness.pool.claim(
            url: otherURL,
            profileID: profileID,
            websiteDataStore: harness.dataStore
        )
        #expect(mismatch == nil)
        // A non-matching panel creation (any other browser panel opening)
        // must not eat the prewarmed pricing page.
        #expect(harness.pool.hasEntry(url: pricingURL, profileID: profileID))

        let match = harness.pool.claim(
            url: pricingURL,
            profileID: profileID,
            websiteDataStore: harness.dataStore
        )
        #expect(match === webView)
    }

    @Test func claimForDifferentProfileKeepsEntry() {
        let harness = PrewarmPoolHarness()
        harness.pool.prewarm(url: pricingURL, profileID: profileID)
        let webView = harness.madeWebViews[0]
        harness.pool.webView(webView, didFinish: nil)

        let mismatch = harness.pool.claim(
            url: pricingURL,
            profileID: UUID(),
            websiteDataStore: harness.dataStore
        )
        #expect(mismatch == nil)
        #expect(harness.pool.hasEntry(url: pricingURL, profileID: profileID))
        harness.pool.discard(reason: "test-teardown")
    }

    @Test func claimWithDifferentDataStoreReturnsNilAndConsumesEntry() {
        let harness = PrewarmPoolHarness()
        harness.pool.prewarm(url: pricingURL, profileID: profileID)
        harness.pool.webView(harness.madeWebViews[0], didFinish: nil)

        let claimed = harness.pool.claim(
            url: pricingURL,
            profileID: profileID,
            websiteDataStore: WKWebsiteDataStore.nonPersistent()
        )

        #expect(claimed == nil)
        #expect(!harness.pool.hasEntry(url: pricingURL, profileID: profileID))
    }

    @Test func provisionalLoadFailureDiscardsEntry() {
        let harness = PrewarmPoolHarness()
        harness.pool.prewarm(url: pricingURL, profileID: profileID)
        let webView = harness.madeWebViews[0]

        harness.pool.webView(
            webView,
            didFailProvisionalNavigation: nil,
            withError: URLError(.notConnectedToInternet)
        )

        #expect(!harness.pool.hasEntry(url: pricingURL, profileID: profileID))
        #expect(webView.window == nil)
    }

    @Test func prewarmAllowsLocalhostHTTPButNotUnlistedHTTPHosts() {
        let harness = PrewarmPoolHarness()
        let localhostURL = URL(string: "http://localhost:3777/app-pricing")!
        harness.pool.prewarm(url: localhostURL, profileID: profileID)
        #expect(harness.pool.hasEntry(url: localhostURL, profileID: profileID))
        harness.pool.discard(reason: "test-teardown")

        // Non-allowlisted plain-http hosts would hit the insecure-HTTP
        // interstitial in a panel, which the hidden prewarm load can't show.
        harness.pool.prewarm(url: URL(string: "http://example.com/")!, profileID: profileID)
        #expect(harness.madeWebViews.count == 1)

        harness.pool.prewarm(url: URL(string: "file:///etc/hosts")!, profileID: profileID)
        #expect(harness.madeWebViews.count == 1)
    }

    @Test func webContentProcessTerminationDiscardsEntry() {
        let harness = PrewarmPoolHarness()
        harness.pool.prewarm(url: pricingURL, profileID: profileID)
        harness.pool.webViewWebContentProcessDidTerminate(harness.madeWebViews[0])

        #expect(!harness.pool.hasEntry(url: pricingURL, profileID: profileID))
    }

    @Test func entryExpiresAfterTimeToLive() async {
        let harness = PrewarmPoolHarness(expirySleep: { _ in })
        harness.pool.prewarm(url: pricingURL, profileID: profileID)
        harness.pool.webView(harness.madeWebViews[0], didFinish: nil)

        var remainingYields = 1000
        while harness.pool.hasEntry(url: pricingURL, profileID: profileID), remainingYields > 0 {
            remainingYields -= 1
            await Task.yield()
        }

        #expect(!harness.pool.hasEntry(url: pricingURL, profileID: profileID))
        #expect(harness.madeWebViews[0].window == nil)
    }
}

@MainActor
private final class CodeWebViewWarmerHarness {
    let dataStore = WKWebsiteDataStore.nonPersistent()
    private(set) var madeWebViews: [CmuxWebView] = []
    private(set) var loadedRequests: [URLRequest] = []
    let warmer: CodeWebViewWarmer

    init(
        capacity: Int = 1,
        targetWindow: NSWindow? = nil,
        presentationFrame: NSRect? = nil
    ) {
        var recordWebView: (@MainActor (CmuxWebView) -> Void)!
        var recordRequest: (@MainActor (URLRequest) -> Void)!
        let dataStore = dataStore
        warmer = CodeWebViewWarmer(
            capacity: capacity,
            makeWebView: { _, _ in
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = dataStore
                let webView = CmuxWebView(frame: .zero, configuration: configuration)
                recordWebView(webView)
                return webView
            },
            startLoad: { _, request in
                recordRequest(request)
            },
            targetWindowProvider: { targetWindow },
            presentationFrameProvider: { _ in presentationFrame },
            observeKeyWindows: false
        )
        recordWebView = { [weak self] in self?.madeWebViews.append($0) }
        recordRequest = { [weak self] in self?.loadedRequests.append($0) }
    }
}

private final class CodeWebViewWarmerResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
struct CodeWebViewWarmerTests {
    @Test func focusedSurfaceFrameUsesTheFocusedBrowserPaneInsteadOfTheWholeWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }

        let workspaceHost = NSView(frame: NSRect(x: 80, y: 40, width: 820, height: 600))
        let browserSlot = WindowBrowserSlotView(
            frame: NSRect(x: 100, y: 20, width: 620, height: 500)
        )
        let responder = CodeWebViewWarmerResponderView(frame: browserSlot.bounds)
        window.contentView?.addSubview(workspaceHost)
        workspaceHost.addSubview(browserSlot)
        browserSlot.addSubview(responder)

        #expect(window.makeFirstResponder(responder))
        #expect(
            CodeWebViewWarmer.focusedSurfaceFrame(in: window)
                == NSRect(x: 180, y: 60, width: 620, height: 500)
        )
    }

    @Test func workspaceSurfaceFrameUnitesVisiblePaneFrames() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }

        let left = WindowBrowserSlotView(frame: NSRect(x: 180, y: 50, width: 360, height: 590))
        let right = WindowBrowserSlotView(frame: NSRect(x: 540, y: 50, width: 360, height: 590))
        window.contentView?.addSubview(left)
        window.contentView?.addSubview(right)

        #expect(
            CodeWebViewWarmer.workspaceSurfaceFrame(in: window)
                == NSRect(x: 180, y: 50, width: 720, height: 590)
        )
    }

    @Test func prewarmFillsTheConfiguredBurstCapacitySerially() {
        let harness = CodeWebViewWarmerHarness(capacity: 4)
        harness.warmer.prewarm(profileID: profileID, websiteDataStore: harness.dataStore)

        #expect(harness.warmer.entryCount == 1)
        #expect(harness.madeWebViews.count == 1)
        #expect(harness.loadedRequests.count == 1)

        for index in 0..<4 {
            harness.madeWebViews[index].onCodeSurfaceReady?()
        }
        #expect(harness.warmer.entryCount == 4)
        #expect(harness.madeWebViews.count == 4)
        #expect(harness.loadedRequests.count == 4)
        #expect(harness.warmer.readyCount == 4)
        harness.warmer.discard(reason: "test-teardown")
    }

    @Test func prewarmKeepsOneConnectedActualClientUntilClaimed() {
        let harness = CodeWebViewWarmerHarness()
        harness.warmer.prewarm(profileID: profileID, websiteDataStore: harness.dataStore)

        #expect(harness.warmer.entryCount == 1)
        #expect(harness.warmer.readyCount == 0)
        #expect(harness.madeWebViews.count == 1)
        #expect(harness.loadedRequests.map(\.url) == [CodeStaticURLSchemeHandler.launcherURL])
        #expect(harness.madeWebViews[0].window != nil)
        #expect(harness.madeWebViews[0].accessibilityHidden() == true)
        #expect(harness.madeWebViews[0].isCodePrewarmAccessibilitySuppressed)
        #expect(harness.madeWebViews[0].accessibilityChildren()?.isEmpty == true)

        harness.warmer.webView(harness.madeWebViews[0], didFinish: nil)
        #expect(harness.warmer.readyCount == 0)

        harness.madeWebViews[0].onCodeSurfaceReady?()
        #expect(harness.warmer.readyCount == 1)

        let claimed = harness.warmer.claim(
            profileID: profileID,
            websiteDataStore: harness.dataStore
        )
        #expect(claimed === harness.madeWebViews[0])
        #expect(claimed?.window == nil)
        #expect(claimed?.superview == nil)
        #expect(claimed?.navigationDelegate == nil)
        #expect(claimed?.accessibilityHidden() == false)
        #expect(claimed?.isCodePrewarmAccessibilitySuppressed == false)
        #expect(claimed?.browserPortalRequiresRenderingStateReattach == true)
        #expect(claimed?.codeSurfaceMessageHandler != nil)
        #expect(harness.warmer.entryCount == 0)
    }

    @Test func claimPrefersTheNewestCompletedFrame() {
        let harness = CodeWebViewWarmerHarness(capacity: 2)
        harness.warmer.prewarm(profileID: profileID, websiteDataStore: harness.dataStore)
        harness.madeWebViews[0].onCodeSurfaceReady?()
        harness.madeWebViews[1].onCodeSurfaceReady?()

        let claimed = harness.warmer.claim(
            profileID: profileID,
            websiteDataStore: harness.dataStore
        )

        #expect(claimed === harness.madeWebViews[1])
        #expect(harness.warmer.entryCount == 1)
        harness.warmer.discard(reason: "test-teardown")
    }

    @Test func sameWindowClaimKeepsTheRenderedViewAttachedUntilPortalAdoption() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }

        let presentationFrame = NSRect(x: 180, y: 0, width: 720, height: 590)
        let harness = CodeWebViewWarmerHarness(
            targetWindow: window,
            presentationFrame: presentationFrame
        )
        harness.warmer.prewarm(profileID: profileID, websiteDataStore: harness.dataStore)
        let webView = harness.madeWebViews[0]
        let hiddenHost = webView.superview
        #expect(webView.window === window)
        #expect(webView.accessibilityHidden() == true)
        #expect(webView.isCodePrewarmAccessibilitySuppressed)
        #expect(webView.accessibilityChildren()?.isEmpty == true)
        #expect(hiddenHost?.accessibilityHidden() == true)
        #expect(hiddenHost?.frame.maxX ?? 0 < 0)
        webView.onCodeSurfaceReady?()

        let claimed = harness.warmer.claim(
            profileID: profileID,
            websiteDataStore: harness.dataStore
        )
        let prewarmHost = claimed?.codePrewarmHostView
        #expect(claimed === webView)
        #expect(claimed?.window === window)
        #expect(claimed?.superview === prewarmHost)
        #expect(claimed?.browserPortalRequiresRenderingStateReattach == false)
        #expect(claimed?.accessibilityHidden() == false)
        #expect(claimed?.isCodePrewarmAccessibilitySuppressed == false)
        #expect(prewarmHost?.accessibilityHidden() == false)
        #expect(prewarmHost?.frame == presentationFrame)
        #expect(window.contentView?.subviews.last === prewarmHost)

        let destination = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(destination)
        if let claimed {
            destination.addSubview(claimed)
        }
        #expect(claimed?.superview === destination)
        #expect(claimed?.codePrewarmHostView == nil)
        #expect(prewarmHost?.superview == nil)
    }

    @Test func workspaceClaimHintPresentsFromRememberedWindowDuringFocusTransition() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }

        let workspaceFrame = NSRect(x: 180, y: 50, width: 720, height: 590)
        window.contentView?.addSubview(WindowBrowserSlotView(frame: workspaceFrame))
        let harness = CodeWebViewWarmerHarness(targetWindow: nil, presentationFrame: nil)
        harness.warmer.prepareNextWorkspaceClaim(in: window)
        harness.warmer.prewarm(profileID: profileID, websiteDataStore: harness.dataStore)
        let webView = harness.madeWebViews[0]
        #expect(webView.window === window)
        webView.onCodeSurfaceReady?()

        let claimed = harness.warmer.claim(
            profileID: profileID,
            websiteDataStore: harness.dataStore
        )

        #expect(claimed === webView)
        #expect(claimed?.codePrewarmHostView?.frame == workspaceFrame)
        #expect(claimed?.isCodePrewarmAccessibilitySuppressed == false)
    }

    @Test func claimBeforeLoadFinishesKeepsTheLoadingFrame() {
        let harness = CodeWebViewWarmerHarness()
        harness.warmer.prewarm(profileID: profileID, websiteDataStore: harness.dataStore)

        let claimed = harness.warmer.claim(
            profileID: profileID,
            websiteDataStore: harness.dataStore
        )

        #expect(claimed == nil)
        #expect(harness.warmer.entryCount == 1)
        harness.warmer.discard(reason: "test-teardown")
    }

    @Test func repeatPrewarmForTheSameProfileKeepsTheExistingWarmer() {
        let harness = CodeWebViewWarmerHarness()
        harness.warmer.prewarm(profileID: profileID, websiteDataStore: harness.dataStore)
        harness.warmer.prewarm(profileID: profileID, websiteDataStore: harness.dataStore)

        #expect(harness.madeWebViews.count == 1)
        #expect(harness.loadedRequests.count == 1)
        harness.warmer.discard(reason: "test-teardown")
    }
}
