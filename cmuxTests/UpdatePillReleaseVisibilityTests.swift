import XCTest
import Foundation
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BrowserInsecureHTTPSettingsTests: XCTestCase {
    func testDefaultAllowlistPatternsArePresent() {
        XCTAssertEqual(
            BrowserInsecureHTTPSettings.normalizedAllowlistPatterns(rawValue: nil),
            ["localhost", "127.0.0.1", "::1", "0.0.0.0", "*.localtest.me"]
        )
    }

    func testWildcardAndExactHostMatching() {
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("localhost", rawAllowlist: nil))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("127.0.0.1", rawAllowlist: nil))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("::1", rawAllowlist: nil))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("0.0.0.0", rawAllowlist: nil))
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

    func testPreparedNavigationRequestPreservesOriginalMethodBodyAndHeaders() throws {
        let url = try XCTUnwrap(URL(string: "http://localtest.me:3000/submit"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("token=abc123".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let prepared = browserPreparedNavigationRequest(request)

        XCTAssertEqual(prepared.url, url)
        XCTAssertEqual(prepared.httpMethod, "POST")
        XCTAssertEqual(prepared.httpBody, Data("token=abc123".utf8))
        XCTAssertEqual(prepared.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(prepared.cachePolicy, .useProtocolCachePolicy)
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

final class TitlebarControlsSizingPolicyTests: XCTestCase {
    func testSchedulePolicyRequiresMeaningfulViewSizeChange() {
        XCTAssertFalse(titlebarControlsShouldScheduleForViewSizeChange(previous: .zero, current: .zero))
        XCTAssertTrue(
            titlebarControlsShouldScheduleForViewSizeChange(
                previous: .zero,
                current: NSSize(width: 240, height: 38)
            )
        )
        XCTAssertFalse(
            titlebarControlsShouldScheduleForViewSizeChange(
                previous: NSSize(width: 240, height: 38),
                current: NSSize(width: 240.2, height: 38.1)
            )
        )
        XCTAssertTrue(
            titlebarControlsShouldScheduleForViewSizeChange(
                previous: NSSize(width: 240, height: 38),
                current: NSSize(width: 247, height: 38)
            )
        )
    }

    func testLayoutApplyPolicySkipsEquivalentSnapshots() {
        let baseline = TitlebarControlsLayoutSnapshot(
            contentSize: NSSize(width: 128, height: 22),
            containerHeight: 28,
            yOffset: 3
        )
        XCTAssertTrue(titlebarControlsShouldApplyLayout(previous: nil, next: baseline))
        XCTAssertFalse(titlebarControlsShouldApplyLayout(previous: baseline, next: baseline))

        let changed = TitlebarControlsLayoutSnapshot(
            contentSize: NSSize(width: 132, height: 22),
            containerHeight: 28,
            yOffset: 3
        )
        XCTAssertTrue(titlebarControlsShouldApplyLayout(previous: baseline, next: changed))
    }
}

final class TitlebarControlsHoverPolicyTests: XCTestCase {
    func testHoverTrackingOnlyEnabledForHoverBackgroundStyles() {
        XCTAssertFalse(titlebarControlsShouldTrackButtonHover(config: TitlebarControlsStyle.classic.config))
        XCTAssertFalse(titlebarControlsShouldTrackButtonHover(config: TitlebarControlsStyle.compact.config))
        XCTAssertFalse(titlebarControlsShouldTrackButtonHover(config: TitlebarControlsStyle.roomy.config))
        XCTAssertTrue(titlebarControlsShouldTrackButtonHover(config: TitlebarControlsStyle.pillGroup.config))
        XCTAssertFalse(titlebarControlsShouldTrackButtonHover(config: TitlebarControlsStyle.softButtons.config))
    }
}
