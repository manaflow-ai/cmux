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


// MARK: - Link open settings
final class BrowserLinkOpenSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "BrowserLinkOpenSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testTerminalLinksDefaultToCmuxBrowser() {
        XCTAssertTrue(BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowser(defaults: defaults))
    }
    func testTerminalLinksPreferenceUsesStoredValue() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowser(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowser(defaults: defaults))
    }
    func testSidebarPullRequestLinksDefaultToCmuxBrowser() {
        XCTAssertTrue(BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser(defaults: defaults))
    }
    func testSidebarPullRequestLinksPreferenceUsesStoredValue() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser(defaults: defaults))
    }
    func testSidebarPullRequestClickabilityDefaultAndStoredValues() {
        XCTAssertTrue(SidebarPullRequestClickabilitySettings.isClickable(defaults: defaults))
        defaults.set(true, forKey: SidebarPullRequestClickabilitySettings.key); XCTAssertTrue(SidebarPullRequestClickabilitySettings.isClickable(defaults: defaults))
        defaults.set(false, forKey: SidebarPullRequestClickabilitySettings.key); XCTAssertFalse(SidebarPullRequestClickabilitySettings.isClickable(defaults: defaults))
    }
    func testOpenCommandInterceptionDefaultsToCmuxBrowser() {
        XCTAssertTrue(BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowser(defaults: defaults))
    }
    func testOpenCommandInterceptionUsesStoredValue() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowser(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowser(defaults: defaults))
    }

    func testOpenCommandInterceptionFallsBackToLegacyLinkToggleWhenUnset() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowser(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowser(defaults: defaults))
    }

    func testSettingsInitialOpenCommandInterceptionValueFallsBackToLegacyLinkToggleWhenUnset() {
        defaults.set(false, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        XCTAssertFalse(BrowserLinkOpenSettings.initialInterceptTerminalOpenCommandInCmuxBrowserValue(defaults: defaults))

        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        XCTAssertTrue(BrowserLinkOpenSettings.initialInterceptTerminalOpenCommandInCmuxBrowserValue(defaults: defaults))
    }

    func testExternalOpenPatternsDefaultToEmpty() {
        XCTAssertTrue(BrowserLinkOpenSettings.externalOpenPatterns(defaults: defaults).isEmpty)
    }

    func testExternalOpenLiteralPatternMatchesCaseInsensitively() {
        defaults.set("openai.com/account/usage", forKey: BrowserLinkOpenSettings.browserExternalOpenPatternsKey)
        XCTAssertTrue(
            BrowserLinkOpenSettings.shouldOpenExternally(
                "https://platform.OPENAI.com/account/usage",
                defaults: defaults
            )
        )
    }

    func testExternalOpenRegexPatternMatchesCaseInsensitively() {
        defaults.set(
            "re:^https?://[^/]*\\.example\\.com/(billing|usage)",
            forKey: BrowserLinkOpenSettings.browserExternalOpenPatternsKey
        )
        XCTAssertTrue(
            BrowserLinkOpenSettings.shouldOpenExternally(
                "https://FOO.example.com/BILLING",
                defaults: defaults
            )
        )
    }

    func testExternalOpenRegexPatternSupportsDigitCharacterClass() {
        defaults.set(
            "re:^https://example\\.com/usage/\\d+$",
            forKey: BrowserLinkOpenSettings.browserExternalOpenPatternsKey
        )
        XCTAssertTrue(
            BrowserLinkOpenSettings.shouldOpenExternally(
                "https://example.com/usage/42",
                defaults: defaults
            )
        )
    }

    func testExternalOpenPatternsIgnoreInvalidRegexEntries() {
        defaults.set("re:(\nexample.com", forKey: BrowserLinkOpenSettings.browserExternalOpenPatternsKey)
        XCTAssertTrue(
            BrowserLinkOpenSettings.shouldOpenExternally(
                "https://example.com/path",
                defaults: defaults
            )
        )
    }
}


