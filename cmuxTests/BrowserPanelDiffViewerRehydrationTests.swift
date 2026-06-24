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
struct BrowserPanelDiffViewerRehydrationTests {
    @Test func routerHTTPURLIsTemporaryHistoryURL() throws {
        let url = try #require(URL(string: "http://127.0.0.1:49152/token/diff.html#/cmux-diff-viewer"))
        #expect(browserIsTemporaryHistoryURL(url))
    }

    @Test func completedHTTPURLRehydratesToSchemeURLFromManifest() throws {
        let token = UUID().uuidString.lowercased()
        let rootURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
        let htmlURL = rootURL.appendingPathComponent("diff-\(token).html", isDirectory: false)
        let manifestURL = rootURL.appendingPathComponent(".manifest-\(token).json", isDirectory: false)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: htmlURL)
            try? FileManager.default.removeItem(at: manifestURL)
        }

        try "<!doctype html><html><body>ready diff</body></html>".write(to: htmlURL, atomically: true, encoding: .utf8)
        let files = [["request_path": "/\(htmlURL.lastPathComponent)", "file_path": htmlURL.path, "mime_type": "text/html"]]
        try JSONSerialization.data(withJSONObject: ["token": token, "files": files], options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)

        for fragment in ["cmux-diff-viewer", "/cmux-diff-viewer"] {
            let staleURL = try #require(URL(string: "http://127.0.0.1:49152/\(token)/\(htmlURL.lastPathComponent)#\(fragment)"))
            let rehydratedURL = try #require(CmuxDiffViewerURLSchemeHandler.shared.restorableSchemeURL(for: staleURL))
            #expect(rehydratedURL.scheme == CmuxDiffViewerURLSchemeHandler.scheme)
            #expect(rehydratedURL.host == token)
            #expect(rehydratedURL.path == "/\(htmlURL.lastPathComponent)")
            #expect(CmuxDiffViewerURLSchemeHandler.shared.registeredFile(for: rehydratedURL) != nil)
        }
    }
}
