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

private final class TerminalLinkPreviewSleepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

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

    @Test func claimBeforeLoadFinishesTransfersTheInFlightWebView() {
        let harness = PrewarmPoolHarness()
        harness.pool.prewarm(url: pricingURL, profileID: profileID)
        let webView = harness.madeWebViews[0]

        let claimed = harness.pool.claim(
            url: pricingURL,
            profileID: profileID,
            websiteDataStore: harness.dataStore
        )

        #expect(claimed?.webView === webView)
        #expect(claimed?.loadState == .loading)
        #expect(claimed?.webView.window == nil)
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

        #expect(claimed?.webView === webView)
        #expect(claimed?.loadState == .finished)
        #expect(claimed?.webView.window == nil)
        #expect(claimed?.webView.superview == nil)
        #expect(claimed?.webView.navigationDelegate == nil)
        // The portal's first-attach refresh only fires the WebKit reattach
        // selectors for webviews marked hidden; without this the adopted view
        // keeps the prewarm-sized layer tree (#7554 dogfood round 1).
        #expect(claimed?.webView.browserPortalRequiresRenderingStateReattach == true)
        #expect(!harness.pool.hasEntry(url: pricingURL, profileID: profileID))
    }

    @Test func previewAttachmentHostsAndThenClaimsTheExactInFlightWebView() {
        let harness = PrewarmPoolHarness()
        harness.pool.prewarm(url: pricingURL, profileID: profileID)
        let webView = harness.madeWebViews[0]
        let previewHost = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 252))
        var observedStates: [BrowserPrewarmedWebViewPool.LoadState] = []
        var dismissCount = 0

        let attachment = harness.pool.attachPreview(
            url: pricingURL,
            profileID: profileID,
            to: previewHost,
            stateDidChange: { observedStates.append($0) },
            didDismiss: { dismissCount += 1 }
        )

        #expect(attachment?.loadState == .loading)
        #expect(webView.superview === previewHost)
        #expect(webView.frame == previewHost.bounds)
        #expect(observedStates == [.loading])

        let claimed = harness.pool.claim(
            url: pricingURL,
            profileID: profileID,
            websiteDataStore: harness.dataStore
        )

        #expect(claimed?.webView === webView)
        #expect(claimed?.loadState == .loading)
        #expect(dismissCount == 1)
        #expect(webView.superview == nil)
    }

    @Test func detachingPreviewReturnsWebViewToHiddenHostAndKeepsItClaimable() throws {
        let harness = PrewarmPoolHarness()
        harness.pool.prewarm(url: pricingURL, profileID: profileID)
        let webView = harness.madeWebViews[0]
        let previewHost = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 252))
        let attachment = try #require(harness.pool.attachPreview(
            url: pricingURL,
            profileID: profileID,
            to: previewHost,
            stateDidChange: { _ in },
            didDismiss: {}
        ))

        harness.pool.detachPreview(attachment)

        #expect(webView.superview !== previewHost)
        #expect(webView.window != nil)
        #expect(harness.pool.hasEntry(url: pricingURL, profileID: profileID))
        let claimed = harness.pool.claim(
            url: pricingURL,
            profileID: profileID,
            websiteDataStore: harness.dataStore
        )
        #expect(claimed?.webView === webView)
    }

    @Test func previewReceivesFinishedLoadStateWithoutReplacingItsWebView() {
        let harness = PrewarmPoolHarness()
        harness.pool.prewarm(url: pricingURL, profileID: profileID)
        let webView = harness.madeWebViews[0]
        let previewHost = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 252))
        var observedStates: [BrowserPrewarmedWebViewPool.LoadState] = []
        let attachment = harness.pool.attachPreview(
            url: pricingURL,
            profileID: profileID,
            to: previewHost,
            stateDidChange: { observedStates.append($0) },
            didDismiss: {}
        )

        harness.pool.webView(webView, didFinish: nil)

        #expect(observedStates == [.loading, .finished])
        #expect(webView.superview === previewHost)
        if let attachment {
            harness.pool.detachPreview(attachment)
        }
        harness.pool.discard(reason: "test-teardown")
    }

    @Test func previewCardRoutesHitsToWebContentWhileBackgroundStaysPassthrough() throws {
        let url = try #require(URL(string: "https://example.com/interactive-preview"))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        let view = TerminalLinkHoverIndicatorView(frame: root.bounds)
        root.addSubview(view)
        #expect(view.preparePreview(url: url, at: NSPoint(x: 450, y: 325)))

        let webContent = NSButton(frame: view.previewWebViewHost.bounds)
        view.previewWebViewHost.addSubview(webContent)
        let webContentPoint = webContent.convert(
            NSPoint(x: webContent.bounds.midX, y: webContent.bounds.midY),
            to: root
        )

        #expect(view.hitTest(webContentPoint) === webContent)
        #expect(view.hitTest(NSPoint(x: 20, y: 20)) == nil)
    }

    @Test func delayedPreviewStartsAfterDwellAndLeavingFirstCancelsIt() async throws {
        let url = try #require(URL(string: "https://example.com/preview"))
        let target = TerminalLinkOpenCoordinator.PreviewTarget(url: url, profileID: profileID)
        let view = TerminalLinkHoverIndicatorView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 650)
        )
        var prewarmedURLs: [URL] = []
        let controller = TerminalLinkPreviewController(
            view: view,
            targetResolver: { _ in target },
            prewarm: { url, _ in prewarmedURLs.append(url) },
            attach: { _, _, _, stateDidChange, _ in
                stateDidChange(.loading)
                return .init(id: UUID(), loadState: .loading)
            },
            detach: { _ in },
            delayMilliseconds: { 650 },
            sleep: { _ in }
        )

        controller.update(
            rawURL: url.absoluteString,
            sourceWorkspaceId: UUID(),
            sourcePanelId: UUID(),
            anchorPoint: NSPoint(x: 450, y: 325)
        )
        #expect(prewarmedURLs.isEmpty)
        #expect(!view.isPreviewVisible)
        await Task.yield()
        await Task.yield()
        #expect(prewarmedURLs == [url])
        #expect(view.previewURL == url)

        controller.update(
            rawURL: nil,
            sourceWorkspaceId: nil,
            sourcePanelId: nil,
            anchorPoint: .zero
        )
        #expect(!view.isPreviewVisible)

        let cancelledView = TerminalLinkHoverIndicatorView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 650)
        )
        var cancelledPrewarms = 0
        let cancelledController = TerminalLinkPreviewController(
            view: cancelledView,
            targetResolver: { _ in target },
            prewarm: { _, _ in cancelledPrewarms += 1 },
            attach: { _, _, _, _, _ in nil },
            detach: { _ in },
            delayMilliseconds: { 650 },
            sleep: { _ in }
        )
        cancelledController.update(
            rawURL: url.absoluteString,
            sourceWorkspaceId: UUID(),
            sourcePanelId: UUID(),
            anchorPoint: NSPoint(x: 450, y: 325)
        )
        cancelledController.update(
            rawURL: nil,
            sourceWorkspaceId: nil,
            sourcePanelId: nil,
            anchorPoint: .zero
        )
        await Task.yield()
        await Task.yield()
        #expect(cancelledPrewarms == 0)
        #expect(!cancelledView.isPreviewVisible)
    }

    @Test func movingWithinTheSameURLDoesNotRestartDwell() async throws {
        let url = try #require(URL(string: "https://example.com/steady-hover"))
        let target = TerminalLinkOpenCoordinator.PreviewTarget(url: url, profileID: profileID)
        let view = TerminalLinkHoverIndicatorView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 650)
        )
        let sleepCounter = TerminalLinkPreviewSleepCounter()
        var prewarmCount = 0
        let controller = TerminalLinkPreviewController(
            view: view,
            targetResolver: { _ in target },
            prewarm: { _, _ in prewarmCount += 1 },
            attach: { _, _, _, _, _ in
                .init(id: UUID(), loadState: .loading)
            },
            detach: { _ in },
            delayMilliseconds: { 650 },
            sleep: { _ in
                sleepCounter.increment()
                try await Task.sleep(for: .milliseconds(30))
            }
        )

        controller.update(
            rawURL: url.absoluteString,
            sourceWorkspaceId: UUID(),
            sourcePanelId: UUID(),
            anchorPoint: NSPoint(x: 300, y: 300)
        )
        var remainingYields = 1_000
        while sleepCounter.value() == 0, remainingYields > 0 {
            remainingYields -= 1
            await Task.yield()
        }
        #expect(sleepCounter.value() == 1)

        controller.update(
            rawURL: url.absoluteString,
            sourceWorkspaceId: UUID(),
            sourcePanelId: UUID(),
            anchorPoint: NSPoint(x: 340, y: 300)
        )
        try await Task.sleep(for: .milliseconds(60))

        #expect(sleepCounter.value() == 1)
        #expect(prewarmCount == 1)
        #expect(view.previewURL == url)
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
        #expect(match?.webView === webView)
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
