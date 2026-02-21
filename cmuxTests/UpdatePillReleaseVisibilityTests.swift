import XCTest
import Foundation
import AppKit
@testable import cmux_DEV

/// Regression test: ensures UpdatePill is never gated behind #if DEBUG in production code paths.
/// This prevents accidentally hiding the update UI in Release builds.
final class UpdatePillReleaseVisibilityTests: XCTestCase {

    /// Source files that must show UpdatePill without #if DEBUG guards.
    private let filesToCheck = [
        "Sources/Update/UpdateTitlebarAccessory.swift",
        "Sources/ContentView.swift",
    ]

    func testUpdatePillNotGatedBehindDebug() throws {
        let projectRoot = findProjectRoot()

        for relativePath in filesToCheck {
            let url = projectRoot.appendingPathComponent(relativePath)
            let source = try String(contentsOf: url, encoding: .utf8)
            let lines = source.components(separatedBy: .newlines)

            // Track #if DEBUG nesting depth.
            var debugDepth = 0

            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed == "#if DEBUG" || trimmed.hasPrefix("#if DEBUG ") {
                    debugDepth += 1
                } else if trimmed == "#endif" && debugDepth > 0 {
                    debugDepth -= 1
                } else if trimmed == "#else" && debugDepth > 0 {
                    // #else inside #if DEBUG means we're in the non-debug branch — that's fine.
                    // But UpdatePill in the #if DEBUG branch (before #else) is the problem.
                    // We handle this by only flagging UpdatePill when debugDepth > 0 and we haven't
                    // hit #else yet. For simplicity, treat #else as flipping out of the guarded section.
                    debugDepth -= 1
                }

                if debugDepth > 0 && trimmed.contains("UpdatePill") {
                    XCTFail(
                        """
                        \(relativePath):\(index + 1) — UpdatePill is inside #if DEBUG. \
                        This hides the update UI in Release builds. Remove the #if DEBUG guard \
                        or move UpdatePill to the #else branch.
                        """
                    )
                }
            }
        }
    }

    private func findProjectRoot() -> URL {
        // Walk up from the test bundle to find the project root (contains GhosttyTabs.xcodeproj).
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = dir.appendingPathComponent("GhosttyTabs.xcodeproj")
            if FileManager.default.fileExists(atPath: marker.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        // Fallback: assume CWD is project root.
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}

/// Regression test: ensure WKWebView can load HTTP development URLs (e.g. *.localtest.me).
final class AppTransportSecurityTests: XCTestCase {
    func testInfoPlistAllowsArbitraryLoadsInWebContent() throws {
        let projectRoot = findProjectRoot()
        let infoPlistURL = projectRoot.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: infoPlistURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
        )
        let ats = try XCTUnwrap(plist["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertEqual(
            ats["NSAllowsArbitraryLoadsInWebContent"] as? Bool,
            true,
            "Resources/Info.plist must allow HTTP loads in WKWebView for local dev hostnames."
        )
    }

    private func findProjectRoot() -> URL {
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = dir.appendingPathComponent("GhosttyTabs.xcodeproj")
            if FileManager.default.fileExists(atPath: marker.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}

final class BrowserInsecureHTTPSettingsTests: XCTestCase {
    func testDefaultAllowlistPatternsArePresent() {
        XCTAssertEqual(
            BrowserInsecureHTTPSettings.normalizedAllowlistPatterns(rawValue: nil),
            ["127.0.0.1", "localhost", "*.localtest.me"]
        )
    }

    func testWildcardAndExactHostMatching() {
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("localhost", rawAllowlist: nil))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("api.localtest.me", rawAllowlist: nil))
        XCTAssertFalse(BrowserInsecureHTTPSettings.isHostAllowed("neverssl.com", rawAllowlist: nil))
    }

    func testCustomAllowlistNormalizesAndDeduplicatesEntries() {
        let raw = """
        localhost
        *.example.com
        127.0.0.1
        https://dev.internal:8080/path
        *.example.com
        """

        XCTAssertEqual(
            BrowserInsecureHTTPSettings.normalizedAllowlistPatterns(rawValue: raw),
            ["localhost", "*.example.com", "127.0.0.1", "dev.internal"]
        )
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("foo.example.com", rawAllowlist: raw))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("dev.internal", rawAllowlist: raw))
        XCTAssertFalse(BrowserInsecureHTTPSettings.isHostAllowed("example.net", rawAllowlist: raw))
    }

    func testBlockDecisionUsesAllowlistAndSchemeRules() throws {
        let localURL = try XCTUnwrap(URL(string: "http://foo.localtest.me:3000"))
        XCTAssertFalse(browserShouldBlockInsecureHTTPURL(localURL, rawAllowlist: nil))

        let insecureURL = try XCTUnwrap(URL(string: "http://neverssl.com"))
        XCTAssertTrue(browserShouldBlockInsecureHTTPURL(insecureURL, rawAllowlist: nil))

        let httpsURL = try XCTUnwrap(URL(string: "https://neverssl.com"))
        XCTAssertFalse(browserShouldBlockInsecureHTTPURL(httpsURL, rawAllowlist: nil))
    }

    func testOneTimeBypassIsConsumedAfterFirstNavigation() throws {
        let insecureURL = try XCTUnwrap(URL(string: "http://neverssl.com"))
        var bypassHostOnce: String? = "neverssl.com"

        XCTAssertTrue(browserShouldConsumeOneTimeInsecureHTTPBypass(
            insecureURL,
            bypassHostOnce: &bypassHostOnce
        ))
        XCTAssertNil(bypassHostOnce)

        // Subsequent visits should prompt again unless host was saved.
        XCTAssertFalse(browserShouldConsumeOneTimeInsecureHTTPBypass(
            insecureURL,
            bypassHostOnce: &bypassHostOnce
        ))
        XCTAssertTrue(browserShouldBlockInsecureHTTPURL(insecureURL, rawAllowlist: nil))
    }

    func testAddAllowedHostPersistsToDefaultsAndUnblocksHTTP() throws {
        let suiteName = "BrowserInsecureHTTPSettingsTests.Persist.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let url = try XCTUnwrap(URL(string: "http://persist-me.test"))
        XCTAssertTrue(browserShouldBlockInsecureHTTPURL(url, defaults: defaults))

        BrowserInsecureHTTPSettings.addAllowedHost("persist-me.test", defaults: defaults)
        let persisted = defaults.string(forKey: BrowserInsecureHTTPSettings.allowlistKey)
        XCTAssertNotNil(persisted)
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("persist-me.test", defaults: defaults))
        XCTAssertFalse(browserShouldBlockInsecureHTTPURL(url, defaults: defaults))
    }

    func testAllowlistSelectionPersistsForProceedAndOpenExternal() {
        XCTAssertTrue(browserShouldPersistInsecureHTTPAllowlistSelection(
            response: .alertFirstButtonReturn,
            suppressionEnabled: true
        ))
        XCTAssertTrue(browserShouldPersistInsecureHTTPAllowlistSelection(
            response: .alertSecondButtonReturn,
            suppressionEnabled: true
        ))
        XCTAssertFalse(browserShouldPersistInsecureHTTPAllowlistSelection(
            response: .alertThirdButtonReturn,
            suppressionEnabled: true
        ))
        XCTAssertFalse(browserShouldPersistInsecureHTTPAllowlistSelection(
            response: .alertSecondButtonReturn,
            suppressionEnabled: false
        ))
    }
}

/// Regression test: ensure new terminal windows are born in full-size content mode so
/// titlebar/content offsets are correct before the first resize.
final class MainWindowLayoutStyleTests: XCTestCase {
    func testCreateMainWindowUsesFullSizeContentViewStyleMask() throws {
        let projectRoot = findProjectRoot()
        let appDelegateURL = projectRoot.appendingPathComponent("Sources/AppDelegate.swift")
        let source = try String(contentsOf: appDelegateURL, encoding: .utf8)

        guard let start = source.range(of: "func createMainWindow("),
              let end = source.range(of: "@objc func checkForUpdates", range: start.upperBound..<source.endIndex) else {
            XCTFail("Could not locate createMainWindow block in Sources/AppDelegate.swift")
            return
        }

        let block = String(source[start.lowerBound..<end.lowerBound])
        let regex = try NSRegularExpression(
            pattern: #"styleMask:\s*\[[^\]]*\.fullSizeContentView"#,
            options: [.dotMatchesLineSeparators]
        )
        let range = NSRange(block.startIndex..<block.endIndex, in: block)
        XCTAssertNotNil(
            regex.firstMatch(in: block, options: [], range: range),
            """
            createMainWindow must include `.fullSizeContentView` in the NSWindow style mask.
            Without it, initial titlebar/content offsets can be wrong until a manual resize.
            """
        )
    }

    private func findProjectRoot() -> URL {
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = dir.appendingPathComponent("GhosttyTabs.xcodeproj")
            if FileManager.default.fileExists(atPath: marker.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
