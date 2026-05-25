import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BrowserShortcutPassthroughHostMatchingTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "BrowserShortcutPassthroughHostMatchingTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    func testEmptyAllowlistReturnsFalseSoDefaultBehaviorIsUnchanged() {
        let defaults = makeIsolatedDefaults()
        XCTAssertFalse(
            BrowserLinkOpenSettings.hostMatchesShortcutPassthrough("127.0.0.1", defaults: defaults),
            "Empty allowlist must NOT passthrough — that's the safety guarantee."
        )
        XCTAssertFalse(
            BrowserLinkOpenSettings.hostMatchesShortcutPassthrough("example.com", defaults: defaults)
        )
    }

    func testExactHostMatch() {
        let defaults = makeIsolatedDefaults()
        defaults.set("127.0.0.1\nlocalhost", forKey: BrowserLinkOpenSettings.shortcutPassthroughHostsKey)

        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesShortcutPassthrough("127.0.0.1", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesShortcutPassthrough("localhost", defaults: defaults))
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesShortcutPassthrough("example.com", defaults: defaults))
    }

    func testWildcardSubdomainMatch() {
        let defaults = makeIsolatedDefaults()
        defaults.set("*.example.com", forKey: BrowserLinkOpenSettings.shortcutPassthroughHostsKey)

        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesShortcutPassthrough("dev.example.com", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesShortcutPassthrough("a.b.example.com", defaults: defaults))
        XCTAssertTrue(
            BrowserLinkOpenSettings.hostMatchesShortcutPassthrough("example.com", defaults: defaults),
            "*.example.com should also match the apex host (consistent with hostsToOpenInEmbeddedBrowser behavior)."
        )
        XCTAssertFalse(BrowserLinkOpenSettings.hostMatchesShortcutPassthrough("notexample.com", defaults: defaults))
    }

    func testURLAccessorStripsPortAndMatchesHost() {
        let defaults = makeIsolatedDefaults()
        defaults.set("127.0.0.1", forKey: BrowserLinkOpenSettings.shortcutPassthroughHostsKey)

        XCTAssertTrue(
            BrowserLinkOpenSettings.urlMatchesShortcutPassthrough(
                URL(string: "http://127.0.0.1:8888/?folder=/x"),
                defaults: defaults
            ),
            "URL host matching should ignore port — code-server on any loopback port is covered by the host entry."
        )
        XCTAssertFalse(
            BrowserLinkOpenSettings.urlMatchesShortcutPassthrough(
                URL(string: "https://example.com/page"),
                defaults: defaults
            )
        )
    }

    func testURLAccessorReturnsFalseForNilOrSchemeOnlyURL() {
        let defaults = makeIsolatedDefaults()
        defaults.set("127.0.0.1", forKey: BrowserLinkOpenSettings.shortcutPassthroughHostsKey)

        XCTAssertFalse(BrowserLinkOpenSettings.urlMatchesShortcutPassthrough(nil, defaults: defaults))
        XCTAssertFalse(
            BrowserLinkOpenSettings.urlMatchesShortcutPassthrough(URL(string: "about:blank"), defaults: defaults)
        )
    }

    func testWhitespaceAndBlankEntriesAreIgnored() {
        let defaults = makeIsolatedDefaults()
        defaults.set(
            "   \n127.0.0.1\n\n  localhost  \n",
            forKey: BrowserLinkOpenSettings.shortcutPassthroughHostsKey
        )

        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesShortcutPassthrough("127.0.0.1", defaults: defaults))
        XCTAssertTrue(BrowserLinkOpenSettings.hostMatchesShortcutPassthrough("localhost", defaults: defaults))
    }
}
