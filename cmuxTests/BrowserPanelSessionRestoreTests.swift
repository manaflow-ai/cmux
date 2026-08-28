import Darwin
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
    func appSessionRestoreKeepsHiddenBrowserPanelsAsLightweightPlaceholders() throws {
        let source = Workspace()
        defer { source.retireFromOwningTabManager() }
        let sourcePane = try #require(source.bonsplitController.focusedPaneId)
        let sourceBrowser = try #require(source.newBrowserSurface(
            inPane: sourcePane,
            // Keep this fixture offline: the test only needs browser identity
            // and persisted metadata, not a network navigation.
            url: URL(string: "about:blank"),
            focus: false
        ))
        let snapshot = source.sessionSnapshot(includeScrollback: false)

        let restored = Workspace()
        defer { restored.retireFromOwningTabManager() }
        let remap = restored.restoreSessionSnapshot(
            snapshot,
            deferBrowserPanels: true
        )
        let restoredPanelID = try #require(remap[sourceBrowser.id])

        #expect(restored.panels[restoredPanelID] is DeferredBrowserPanel)
        let roundTripped = restored.sessionSnapshot(includeScrollback: false)
        #expect(roundTripped.panels.contains { panel in
            panel.id == restoredPanelID && panel.type == .browser && panel.browser != nil
        })

        #expect(!restored.requestDeferredBrowserMaterialization(
            panelId: restoredPanelID,
            isVisibleInUI: false
        ))
        #expect(restored.panels[restoredPanelID] is DeferredBrowserPanel)
        #expect(restored.requestDeferredBrowserMaterialization(
            panelId: restoredPanelID,
            isVisibleInUI: true,
            reason: "test.visible"
        ))
        #expect(restored.panels[restoredPanelID] is BrowserPanel)
        #expect(restored.requestDeferredBrowserMaterialization(
            panelId: restoredPanelID,
            isVisibleInUI: true,
            reason: "test.idempotent"
        ))
    }

    @Test
    func appSessionRestoreDoesNotMaterializeSelectedBrowsersDuringTopologyAssembly() throws {
        let firstPanelID = UUID()
        let secondPanelID = UUID()
        let browserSnapshot: (UUID, String) -> SessionPanelSnapshot = { id, url in
            SessionPanelSnapshot(
                id: id,
                type: .browser,
                title: url,
                customTitle: nil,
                directory: nil,
                isPinned: false,
                isManuallyUnread: false,
                listeningPorts: [],
                ttyName: nil,
                terminal: nil,
                browser: SessionBrowserPanelSnapshot(
                    urlString: url,
                    profileID: nil,
                    shouldRenderWebView: true,
                    pageZoom: 1,
                    developerToolsVisible: false,
                    backHistoryURLStrings: [],
                    forwardHistoryURLStrings: []
                ),
                markdown: nil,
                filePreview: nil,
                rightSidebarTool: nil,
                project: nil
            )
        }
        let snapshot = SessionWorkspaceSnapshot(
            processTitle: "Restored browser panes",
            customTitle: nil,
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            terminalScrollBarHidden: nil,
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            focusedPanelId: firstPanelID,
            layout: .split(SessionSplitLayoutSnapshot(
                orientation: .horizontal,
                dividerPosition: 0.5,
                first: .pane(SessionPaneLayoutSnapshot(
                    panelIds: [firstPanelID],
                    selectedPanelId: firstPanelID
                )),
                second: .pane(SessionPaneLayoutSnapshot(
                    panelIds: [secondPanelID],
                    selectedPanelId: secondPanelID
                ))
            )),
            panels: [
                browserSnapshot(firstPanelID, "https://example.com/first"),
                browserSnapshot(secondPanelID, "https://example.com/second"),
            ],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            remote: nil
        )

        let restored = Workspace()
        defer { restored.retireFromOwningTabManager() }
        let remap = restored.restoreSessionSnapshot(
            snapshot,
            deferBrowserPanels: true
        )

        #expect(remap.count == 2)
        #expect(restored.panels.values.count == 2)
        #expect(restored.panels.values.allSatisfy { $0 is DeferredBrowserPanel })
    }
}
