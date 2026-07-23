import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Artifact HTML preview security")
struct ArtifactHTMLPreviewSecurityTests {
    @Test("Untrusted HTML is wrapped in an isolated non-navigating data document")
    func wrapsActiveContentInASandbox() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-html-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("artifact.html", isDirectory: false)
        try """
        <script>top.document.title = 'owned'</script>
        <img src="https://example.invalid/tracker.png">
        <a href="file:///private/sibling.txt">sibling</a>
        """.write(to: source, atomically: true, encoding: .utf8)

        let document = try await ArtifactHTMLPreviewDocument.load(sourceURL: source)
        let prefix = "data:text/html;base64,"
        #expect(document.url.absoluteString.hasPrefix(prefix))
        let encoded = String(document.url.absoluteString.dropFirst(prefix.count))
        let data = try #require(Data(base64Encoded: encoded))
        let wrapper = String(decoding: data, as: UTF8.self)

        #expect(wrapper.contains("sandbox=\"\""))
        #expect(wrapper.contains("default-src 'none'"))
        #expect(wrapper.contains("script-src 'none'"))
        #expect(wrapper.contains("connect-src 'none'"))
        #expect(wrapper.contains("navigate-to 'none'"))
        #expect(!wrapper.contains(source.path))
    }

    @Test("Artifact previews reject symbolic links and oversized sources")
    func rejectsUntrustedSourceEntries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-html-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.html", isDirectory: false)
        try "<p>private</p>".write(to: target, atomically: true, encoding: .utf8)
        let symbolicLink = root.appendingPathComponent("linked.html", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: target)
        let oversized = root.appendingPathComponent("oversized.html", isDirectory: false)
        try Data(repeating: 0x20, count: 8 * 1024 * 1024 + 1).write(to: oversized)

        await #expect(throws: CocoaError.self) {
            _ = try await ArtifactHTMLPreviewDocument.load(sourceURL: symbolicLink)
        }
        await #expect(throws: CocoaError.self) {
            _ = try await ArtifactHTMLPreviewDocument.load(sourceURL: oversized)
        }
    }

    @Test("Artifact previews use an ephemeral script-free WebKit configuration")
    @MainActor
    func configuresAnIsolatedWebView() {
        let configuration = ArtifactHTMLPreviewWebViewPolicy.makeConfiguration()

        #expect(!configuration.websiteDataStore.isPersistent)
        #expect(!configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(configuration.userContentController.userScripts.isEmpty)
        #expect(!configuration.preferences.javaScriptCanOpenWindowsAutomatically)
    }

    @Test("Artifact previews permit only their wrapper and inert srcdoc frame")
    func blocksFollowUpNavigationAndPopups() throws {
        let documentURL = try #require(URL(string: "data:text/html;base64,PGh0bWw+"))
        let policy = ArtifactHTMLPreviewNavigationPolicy(documentURL: documentURL)

        #expect(policy.allowsNavigation(to: documentURL, targetIsMainFrame: true))
        #expect(policy.allowsNavigation(to: URL(string: "about:srcdoc"), targetIsMainFrame: false))
        #expect(!policy.allowsNavigation(to: URL(string: "https://example.com"), targetIsMainFrame: true))
        #expect(!policy.allowsNavigation(to: URL(fileURLWithPath: "/private/sibling.txt"), targetIsMainFrame: false))
        #expect(!policy.allowsNavigation(to: documentURL, targetIsMainFrame: nil))
    }

    @Test("Artifact previews never enter normal browser session persistence")
    func excludesPreviewDocumentsFromRestoration() throws {
        let documentURL = try #require(URL(string: "data:text/html;base64,PGh0bWw+"))

        #expect(!BrowserPanelContentMode.artifactHTMLPreview(
            documentURL: documentURL
        ).allowsSessionPersistence)
        #expect(BrowserPanelContentMode.standard.allowsSessionPersistence)
    }

    @Test("Closing an artifact preview never stages it for normal browser reopening")
    @MainActor
    func excludesPreviewDocumentsFromClosedBrowserHistory() throws {
        let workspace = Workspace()
        let documentURL = try #require(URL(string: "data:text/html;base64,PGh0bWw+"))
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let browserPanel = try #require(workspace.newBrowserSurface(
            inPane: paneID,
            url: documentURL,
            focus: false,
            creationPolicy: .artifactPreview
        ))
        let tabID = try #require(workspace.surfaceIdFromPanelId(browserPanel.id))
        let tab = try #require(workspace.bonsplitController.tab(tabID))
        var closedSnapshot: ClosedBrowserPanelRestoreSnapshot?
        workspace.onClosedBrowserPanel = { snapshot in
            closedSnapshot = snapshot
        }

        #expect(workspace.splitTabBar(
            workspace.bonsplitController,
            shouldCloseTab: tab,
            inPane: paneID
        ))
        workspace.splitTabBar(
            workspace.bonsplitController,
            didCloseTab: tabID,
            fromPane: paneID
        )

        #expect(closedSnapshot == nil)
    }
}
