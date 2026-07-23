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
    func wrapsActiveContentInASandbox() throws {
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

        let document = try ArtifactHTMLPreviewDocument(sourceURL: source)
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
}
