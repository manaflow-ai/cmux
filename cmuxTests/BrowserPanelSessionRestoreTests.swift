import Darwin
import CmuxBrowser
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
    func legacyOmnibarVisibilityRestoresForRegularBrowser() throws {
        let url = try #require(URL(string: "https://example.com/legacy-omnibar"))
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }

        panel.restoreSessionSnapshot(SessionBrowserPanelSnapshot(
            urlString: url.absoluteString,
            profileID: nil,
            shouldRenderWebView: false,
            pageZoom: 1.0,
            developerToolsVisible: false,
            omnibarVisible: false,
            backHistoryURLStrings: [],
            forwardHistoryURLStrings: []
        ))

        #expect(panel.chromeVisibility == .hidden)
    }

    @Test
    func legacyOmnibarVisibilityRestoresForDiffViewer() throws {
        let token = UUID().uuidString.lowercased()
        let requestPath = "/index.html"
        let trustedRootURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
        let sessionDirectoryURL = trustedRootURL.appendingPathComponent(token, isDirectory: true)
        let pageURL = sessionDirectoryURL.appendingPathComponent("index.html", isDirectory: false)
        let manifestURL = trustedRootURL
            .appendingPathComponent(".manifest-\(token).json", isDirectory: false)
        let leaseURL = trustedRootURL
            .appendingPathComponent(".session-lease-\(token).lock", isDirectory: false)

        defer {
            try? FileManager.default.removeItem(at: sessionDirectoryURL)
            try? FileManager.default.removeItem(at: manifestURL)
            try? FileManager.default.removeItem(at: leaseURL)
        }

        try FileManager.default.createDirectory(
            at: sessionDirectoryURL,
            withIntermediateDirectories: true
        )
        try Data("<!doctype html>".utf8).write(to: pageURL, options: .atomic)
        let manifest: [String: Any] = [
            "files": [[
                "request_path": requestPath,
                "file_path": pageURL.path,
                "mime_type": "text/html",
            ]],
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        try manifestData.write(to: manifestURL, options: .atomic)

        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }

        panel.restoreSessionSnapshot(SessionBrowserPanelSnapshot(
            urlString: nil,
            profileID: nil,
            shouldRenderWebView: false,
            pageZoom: 1.0,
            developerToolsVisible: false,
            omnibarVisible: true,
            backHistoryURLStrings: [],
            forwardHistoryURLStrings: [],
            diffViewerToken: token,
            diffViewerRequestPath: requestPath
        ))

        #expect(panel.chromeVisibility == .visible)
        let expectedURL = try #require(
            CmuxDiffViewerURLSchemeHandler.diffViewerURL(
                token: token,
                requestPath: requestPath
            )
        )
        #expect(panel.currentURL == expectedURL)
    }

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
    func chromiumSessionSnapshotKeepsEngineHistoryURLs() throws {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            engine: .chromium
        )
        defer { panel.close() }

        let current = try #require(URL(string: "https://example.com/current"))
        let back = try #require(URL(string: "https://example.com/back"))
        let forward = try #require(URL(string: "https://example.com/forward"))
        panel.applyChromiumSnapshot(
            ChromiumSessionSnapshot(
                state: .running(nil),
                currentURL: current,
                canGoBack: true,
                canGoForward: true,
                backHistoryURLs: [back],
                forwardHistoryURLs: [forward]
            )
        )

        let history = panel.sessionNavigationHistorySnapshot()
        #expect(history.backHistoryURLStrings == [back.absoluteString])
        #expect(history.forwardHistoryURLStrings == [forward.absoluteString])
        #expect(panel.canGoBack)
        #expect(panel.canGoForward)
    }
}
