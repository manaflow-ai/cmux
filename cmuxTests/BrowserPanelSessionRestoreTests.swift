import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserPanelSessionRestoreTests {
    @Test
    func sessionRestoreDefersWebKitLoadUntilPanelIsVisible() throws {
        let url = try #require(URL(string: "https://example.com/restored"))
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }

        let originalWebView = panel.webView
        panel.restoreSessionSnapshot(SessionBrowserPanelSnapshot(
            urlString: url.absoluteString,
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1.0,
            developerToolsVisible: false,
            backHistoryURLStrings: ["https://example.com/back"],
            forwardHistoryURLStrings: ["https://example.com/forward"]
        ))

        #expect(panel.webView === originalWebView)
        #expect(panel.currentURL == url)
        #expect(!panel.shouldRenderWebView)
        #expect(panel.webViewLifecycleState == .discarded)
        #expect(panel.shouldRenderWebViewForSessionSnapshot())
        #expect(panel.canGoBack)
        #expect(panel.canGoForward)

        panel.noteWebViewVisibility(true, reason: "test.visible")

        #expect(panel.shouldRenderWebView)
        #expect(panel.webViewLifecycleState == .liveVisible)
        #expect(panel.currentURL == url)
        #expect(panel.canGoBack)
        #expect(panel.canGoForward)

        let history = panel.sessionNavigationHistorySnapshot()
        #expect(history.backHistoryURLStrings == ["https://example.com/back"])
        #expect(history.forwardHistoryURLStrings == ["https://example.com/forward"])
    }

    @Test
    func sessionRestorePreservesMinimumViewportSize() throws {
        let url = try #require(URL(string: "https://example.com/restored"))
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }

        panel.restoreSessionSnapshot(SessionBrowserPanelSnapshot(
            urlString: url.absoluteString,
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1.0,
            minimumViewportWidth: 1400,
            minimumViewportHeight: 900,
            developerToolsVisible: false,
            backHistoryURLStrings: nil,
            forwardHistoryURLStrings: nil
        ))

        let viewportSize = try #require(panel.currentMinimumViewportSize())
        #expect(viewportSize.width == 1400)
        #expect(viewportSize.height == 900)
    }

    @Test
    func browserSnapshotRoundTripPreservesMinimumViewportSize() throws {
        let source = SessionBrowserPanelSnapshot(
            urlString: "https://example.com/current",
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1.2,
            minimumViewportWidth: 1400,
            minimumViewportHeight: 900,
            developerToolsVisible: false,
            backHistoryURLStrings: nil,
            forwardHistoryURLStrings: nil
        )

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(SessionBrowserPanelSnapshot.self, from: data)

        #expect(decoded.minimumViewportWidth == 1400)
        #expect(decoded.minimumViewportHeight == 900)
    }
}
