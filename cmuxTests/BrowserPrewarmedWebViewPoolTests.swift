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
