import XCTest
import Combine
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Network

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Navigable URL resolution, read access, external schemes, and host whitelist
final class BrowserNavigableURLResolutionTests: XCTestCase {
    func testResolvesFileSchemeAsNavigableURL() throws {
        let resolved = try XCTUnwrap(resolveBrowserNavigableURL("file:///tmp/cmux-local-test.html"))
        XCTAssertTrue(resolved.isFileURL)
        XCTAssertEqual(resolved.path, "/tmp/cmux-local-test.html")
    }

    func testResolvesBareLocalhostSubdomainAsHTTPURL() throws {
        let resolved = try XCTUnwrap(resolveBrowserNavigableURL("api.localhost:3000"))
        XCTAssertEqual(resolved.scheme, "http")
        XCTAssertEqual(resolved.host, "api.localhost")
        XCTAssertEqual(resolved.port, 3000)

        let nested = try XCTUnwrap(resolveBrowserNavigableURL("deep.api.localhost/path"))
        XCTAssertEqual(nested.scheme, "http")
        XCTAssertEqual(nested.host, "deep.api.localhost")
        XCTAssertEqual(nested.path, "/path")
    }

    func testRejectsNonWebNonFileScheme() {
        XCTAssertNil(resolveBrowserNavigableURL("mailto:test@example.com"))
        XCTAssertNil(resolveBrowserNavigableURL("ftp://example.com/file.html"))
    }

    func testRejectsHostOnlyFileURL() {
        XCTAssertNil(resolveBrowserNavigableURL("file://example.html"))
    }
}


final class BrowserReadAccessURLTests: XCTestCase {
    func testUsesParentDirectoryForFileURL() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = tempRoot.appendingPathComponent("BrowserReadAccessURLTests-\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent("sample.html")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "<html></html>".write(to: file, atomically: true, encoding: .utf8)

        let readAccessURL = try XCTUnwrap(browserReadAccessURL(forLocalFileURL: file))
        XCTAssertEqual(readAccessURL.standardizedFileURL, dir.standardizedFileURL)
    }

    func testUsesDirectoryURLWhenTargetIsDirectory() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = tempRoot.appendingPathComponent("BrowserReadAccessURLTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let readAccessURL = try XCTUnwrap(browserReadAccessURL(forLocalFileURL: dir))
        XCTAssertEqual(readAccessURL.standardizedFileURL, dir.standardizedFileURL)
    }

    func testUsesParentDirectoryWhenFileDoesNotExist() throws {
        let missing = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).html")
        let readAccessURL = try XCTUnwrap(browserReadAccessURL(forLocalFileURL: missing))
        XCTAssertEqual(readAccessURL.standardizedFileURL, missing.deletingLastPathComponent().standardizedFileURL)
    }

    func testReturnsNilForHostOnlyFileURL() throws {
        let hostOnly = try XCTUnwrap(URL(string: "file://example.html"))
        XCTAssertNil(browserReadAccessURL(forLocalFileURL: hostOnly))
    }
}


final class BrowserExternalNavigationSchemeTests: XCTestCase {
    func testCustomAppSchemesOpenExternally() throws {
        let discord = try XCTUnwrap(URL(string: "discord://login/one-time?token=abc"))
        let slack = try XCTUnwrap(URL(string: "slack://open"))
        let zoom = try XCTUnwrap(URL(string: "zoommtg://zoom.us/join"))
        let mailto = try XCTUnwrap(URL(string: "mailto:test@example.com"))

        XCTAssertTrue(browserShouldOpenURLExternally(discord))
        XCTAssertTrue(browserShouldOpenURLExternally(slack))
        XCTAssertTrue(browserShouldOpenURLExternally(zoom))
        XCTAssertTrue(browserShouldOpenURLExternally(mailto))
    }

    func testEmbeddedBrowserSchemesStayInWebView() throws {
        let https = try XCTUnwrap(URL(string: "https://example.com"))
        let http = try XCTUnwrap(URL(string: "http://example.com"))
        let about = try XCTUnwrap(URL(string: "about:blank"))
        let data = try XCTUnwrap(URL(string: "data:text/plain,hello"))
        let file = try XCTUnwrap(URL(string: "file:///tmp/cmux-local-test.html"))
        let blob = try XCTUnwrap(URL(string: "blob:https://example.com/550e8400-e29b-41d4-a716-446655440000"))
        let diffViewer = try XCTUnwrap(URL(string: "cmux-diff-viewer://0123456789abcdef/diff.html"))
        let javascript = try XCTUnwrap(URL(string: "javascript:void(0)"))
        let webkitInternal = try XCTUnwrap(URL(string: "applewebdata://local/page"))

        XCTAssertFalse(browserShouldOpenURLExternally(https))
        XCTAssertFalse(browserShouldOpenURLExternally(http))
        XCTAssertFalse(browserShouldOpenURLExternally(about))
        XCTAssertFalse(browserShouldOpenURLExternally(data))
        XCTAssertFalse(browserShouldOpenURLExternally(file))
        XCTAssertFalse(browserShouldOpenURLExternally(blob))
        XCTAssertFalse(browserShouldOpenURLExternally(diffViewer))
        XCTAssertFalse(browserShouldOpenURLExternally(javascript))
        XCTAssertFalse(browserShouldOpenURLExternally(webkitInternal))
    }

    func testCustomAppSchemesRouteExternallyFromSubframes() throws {
        let vscode = try XCTUnwrap(URL(string: "vscode://file/Users/example/project/README.md"))

        XCTAssertTrue(browserShouldRouteExternalNavigation(vscode))
        XCTAssertEqual(browserExternalNavigationAction(for: vscode), .promptToOpenApp(vscode))
    }

    func testEmbeddedSubframeNavigationStaysInWebView() throws {
        let https = try XCTUnwrap(URL(string: "https://example.com/iframe"))

        XCTAssertFalse(browserShouldRouteExternalNavigation(https))
    }

    func testIntentBrowserFallbackURLExtraction() throws {
        let intent = try XCTUnwrap(URL(string: "intent://join/abc#Intent;scheme=zoommtg;package=us.zoom.videomeetings;S.browser_fallback_url=https%3A%2F%2Fzoom.us%2Fjoin%2Fabc;end"))
        let fallback = try XCTUnwrap(URL(string: "https://zoom.us/join/abc"))

        XCTAssertEqual(browserIntentFallbackURL(for: intent), fallback)
        XCTAssertEqual(browserExternalNavigationAction(for: intent), .browserFallback(fallback))
    }

    func testIntentBrowserFallbackURLRejectsExternalSchemes() throws {
        let intent = try XCTUnwrap(URL(string: "intent://open#Intent;S.browser_fallback_url=slack%3A%2F%2Fopen;end"))

        XCTAssertNil(browserIntentFallbackURL(for: intent))
    }
}


final class BrowserHostWhitelistTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "BrowserHostWhitelistTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testEmptyWhitelistAllowsAll() {
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
    }

    func testExactMatch() {
        defaults.set("localhost\n127.0.0.1", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("127.0.0.1", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
    }

    func testExactMatchIsCaseInsensitive() {
        defaults.set("LocalHost", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("LOCALHOST", defaults: defaults))
    }

    func testWildcardSuffix() {
        defaults.set("*.localtest.me", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("app.localtest.me", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("sub.app.localtest.me", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localtest.me", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
    }

    func testWildcardIsCaseInsensitive() {
        defaults.set("*.Example.COM", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("sub.example.com", defaults: defaults))
    }

    func testBlankLinesAndWhitespaceIgnored() {
        defaults.set("  localhost  \n\n  127.0.0.1  \n", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("127.0.0.1", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
    }

    func testMixedExactAndWildcard() {
        defaults.set("localhost\n127.0.0.1\n*.local.dev", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("127.0.0.1", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("app.local.dev", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("github.com", defaults: defaults))
    }

    func testDefaultWhitelistIsEmpty() {
        let patterns = BrowserLinkOpenSettings.hostWhitelist(defaults: defaults)
        XCTAssertTrue(patterns.isEmpty)
    }

    func testWildcardRequiresDotBoundary() {
        defaults.set("*.example.com", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("badexample.com", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com.evil", defaults: defaults))
    }

    func testWhitelistNormalizesSchemesPortsAndTrailingDots() {
        defaults.set("https://LOCALHOST:3000/path\n*.Example.COM:443", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("localhost.", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("api.example.com", defaults: defaults))
    }

    func testInvalidWhitelistEntriesDoNotImplicitlyAllowAll() {
        defaults.set("http://\n*.\n", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesWhitelist("example.com", defaults: defaults))
    }

    func testUnicodeWhitelistEntryMatchesPunycodeHost() {
        defaults.set("b\u{00FC}cher.example", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesWhitelist("xn--bcher-kva.example", defaults: defaults))
    }
}


