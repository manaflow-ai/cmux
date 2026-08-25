import Foundation
import CmuxSettings
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

        let document = try await ArtifactHTMLPreviewDocument.load(
            sourceURL: source,
            allowedRoot: root
        )
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
        try Data().write(to: oversized)
        let oversizedHandle = try FileHandle(forWritingTo: oversized)
        try oversizedHandle.truncate(
            atOffset: UInt64(8 * 1024 * 1024) + 1
        )
        try oversizedHandle.close()

        await #expect(throws: CocoaError.self) {
            _ = try await ArtifactHTMLPreviewDocument.load(
                sourceURL: symbolicLink,
                allowedRoot: root
            )
        }
        await #expect(throws: CocoaError.self) {
            _ = try await ArtifactHTMLPreviewDocument.load(
                sourceURL: oversized,
                allowedRoot: root
            )
        }
    }

    @Test("Artifact previews reject a swapped parent symlink")
    func rejectsSwappedParentSymlink() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-html-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-html-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let parent = root.appendingPathComponent("session", isDirectory: true)
        let source = parent.appendingPathComponent("artifact.html")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try "<p>authorized</p>".write(to: source, atomically: true, encoding: .utf8)
        try "<p>outside</p>".write(
            to: outside.appendingPathComponent("artifact.html"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)

        #expect(ArtifactSidebarFileAccess().validatedFileURL(
            for: source,
            artifactRoot: root
        ) == nil)
        await #expect(throws: CocoaError.self) {
            _ = try await ArtifactHTMLPreviewDocument.load(
                sourceURL: source,
                allowedRoot: root
            )
        }
    }

    @Test("Descriptor-backed artifact reads stay on the opened inode")
    func descriptorReadSurvivesPathReplacement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-open-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-open-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("artifact.txt")
        try "authorized".write(to: source, atomically: true, encoding: .utf8)
        let opened = try #require(
            ArtifactSidebarFileAccess().openedFile(for: source, artifactRoot: root)
        )
        try "outside".write(
            to: outside.appendingPathComponent("artifact.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(
            at: source,
            withDestinationURL: outside.appendingPathComponent("artifact.txt")
        )

        #expect(try String(contentsOf: opened.readURL, encoding: .utf8) == "authorized")
        let temporary = try #require(opened.makeTemporaryPreviewURL())
        defer { try? FileManager.default.removeItem(at: temporary) }
        #expect(temporary.pathExtension == "txt")
        #expect(try String(contentsOf: temporary, encoding: .utf8) == "authorized")
        let filePermissions = try #require(
            FileManager.default.attributesOfItem(atPath: temporary.path)[.posixPermissions]
                as? NSNumber
        ).intValue
        let directoryPermissions = try #require(
            FileManager.default.attributesOfItem(
                atPath: temporary.deletingLastPathComponent().path
            )[.posixPermissions] as? NSNumber
        ).intValue
        #expect(filePermissions & 0o077 == 0)
        #expect(directoryPermissions & 0o077 == 0)
        let asyncTemporary = try #require(
            await opened.makeTemporaryPreviewURLAsync()
        )
        defer { try? FileManager.default.removeItem(at: asyncTemporary) }
        #expect(try String(contentsOf: asyncTemporary, encoding: .utf8) == "authorized")
    }

    @Test("Concurrent descriptor previews keep independent offsets and stay bounded")
    func concurrentDescriptorPreviewsStayBounded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-preview-quota-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("artifact.txt", isDirectory: false)
        try "authorized".write(to: source, atomically: true, encoding: .utf8)
        let opened = try #require(
            ArtifactSidebarFileAccess().openedFile(for: source, artifactRoot: root)
        )

        var previews: [URL] = []
        await withTaskGroup(of: URL?.self) { group in
            for _ in 0..<300 {
                group.addTask {
                    await opened.makeTemporaryPreviewURLAsync(maximumBytes: 32)
                }
            }
            for await preview in group {
                if let preview { previews.append(preview) }
            }
        }
        defer {
            for preview in previews {
                try? FileManager.default.removeItem(at: preview)
            }
        }

        #expect(!previews.isEmpty)
        #expect(previews.count <= 256)
        for preview in previews {
            #expect(try String(contentsOf: preview, encoding: .utf8) == "authorized")
        }
    }

    @Test("Artifact previews use an ephemeral script-free WebKit configuration")
    @MainActor
    func configuresAnIsolatedWebView() {
        let configuration = ArtifactHTMLPreviewWebViewFactory(
            websiteDataStore: .nonPersistent()
        ).makeConfiguration()

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
        #expect(policy.allowsNavigation(
            to: URL(string: documentURL.absoluteString + "#section"),
            targetIsMainFrame: true
        ))
        #expect(policy.allowsNavigation(to: URL(string: "about:srcdoc"), targetIsMainFrame: false))
        #expect(policy.allowsNavigation(to: URL(string: "about:srcdoc#section"), targetIsMainFrame: false))
        #expect(!policy.allowsNavigation(to: URL(string: "https://example.com"), targetIsMainFrame: true))
        #expect(!policy.allowsNavigation(to: URL(fileURLWithPath: "/private/sibling.txt"), targetIsMainFrame: false))
        #expect(!policy.allowsNavigation(to: documentURL, targetIsMainFrame: nil))
    }

    @Test("App-owned preview documents use the trusted internal allowlist path")
    func trustedPreviewURLSurvivesManagedAllowlist() throws {
        let documentURL = try #require(URL(string: "data:text/html;base64,PGh0bWw+"))
        let allowlist = BrowserURLAllowlistPolicy(managedPatterns: ["internal.example"])

        #expect(!allowlist.allows(documentURL))
        #expect(allowlist.allowsTrustedInternalURL(documentURL))
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
