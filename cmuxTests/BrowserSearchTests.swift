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


// MARK: - Search engines and search settings
final class BrowserSearchEngineTests: XCTestCase {
    func testGoogleSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.google.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertEqual(url.path, "/search")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }

    func testDuckDuckGoSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.duckduckgo.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "duckduckgo.com")
        XCTAssertEqual(url.path, "/")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }

    func testBingSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.bing.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "www.bing.com")
        XCTAssertEqual(url.path, "/search")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }

    func testKagiSearchURL() throws {
        let url = try XCTUnwrap(BrowserSearchEngine.kagi.searchURL(query: "hello world"))
        XCTAssertEqual(url.host, "kagi.com")
        XCTAssertEqual(url.path, "/search")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }

    func testAdditionalPresetSearchURLs() throws {
        let expectations: [(BrowserSearchEngine, String, String)] = [
            (.brave, "search.brave.com", "q=hello%20world"),
            (.perplexity, "www.perplexity.ai", "q=hello%20world"),
            (.exa, "exa.ai", "q=hello%20world"),
            (.yahoo, "search.yahoo.com", "p=hello%20world"),
            (.ecosia, "www.ecosia.org", "q=hello%20world"),
            (.qwant, "www.qwant.com", "q=hello%20world"),
            (.mojeek, "www.mojeek.com", "q=hello%20world"),
            (.wikipedia, "en.wikipedia.org", "search=hello%20world"),
            (.github, "github.com", "q=hello%20world"),
            (.baidu, "www.baidu.com", "wd=hello%20world"),
            (.yandex, "yandex.com", "text=hello%20world"),
        ]

        for (engine, host, encodedQuery) in expectations {
            let url = try XCTUnwrap(engine.searchURL(query: "hello world"), engine.rawValue)
            XCTAssertEqual(url.host, host, engine.rawValue)
            XCTAssertTrue(url.absoluteString.contains(encodedQuery), engine.rawValue)
        }
    }

    func testCustomSearchURLTemplateReplacesQueryPlaceholder() throws {
        let url = try XCTUnwrap(BrowserSearchSettings.searchURL(
            fromTemplate: "https://search.example.test/find?q={query}&src=cmux",
            query: "hello world"
        ))

        XCTAssertEqual(url.host, "search.example.test")
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
        XCTAssertTrue(url.absoluteString.contains("src=cmux"))
    }

    func testCustomSearchURLTemplateReplacesPercentPlaceholder() throws {
        let url = try XCTUnwrap(BrowserSearchSettings.searchURL(
            fromTemplate: "https://search.example.test/find?term=%s",
            query: "c++ && swift"
        ))

        XCTAssertEqual(url.host, "search.example.test")
        XCTAssertTrue(url.absoluteString.contains("term=c%2B%2B%20%26%26%20swift"))
    }

    func testCustomSearchURLTemplateAppendsQueryItemWhenPlaceholderIsMissing() throws {
        let url = try XCTUnwrap(BrowserSearchSettings.searchURL(
            fromTemplate: "https://search.example.test/find?source=cmux",
            query: "hello world"
        ))

        XCTAssertEqual(url.host, "search.example.test")
        XCTAssertTrue(url.absoluteString.contains("source=cmux"))
        XCTAssertTrue(url.absoluteString.contains("q=hello%20world"))
    }

    func testCustomSearchURLTemplateFallbackEscapesPlusSigns() throws {
        let url = try XCTUnwrap(BrowserSearchSettings.searchURL(
            fromTemplate: "https://search.example.test/find?source=cmux",
            query: "c++ && swift"
        ))

        XCTAssertEqual(url.host, "search.example.test")
        XCTAssertTrue(url.absoluteString.contains("source=cmux"))
        XCTAssertTrue(url.absoluteString.contains("q=c%2B%2B%20%26%26%20swift"))
        XCTAssertFalse(url.absoluteString.contains("q=c++"))
    }

    func testCustomSearchURLTemplateRejectsNonHTTPURLs() {
        XCTAssertNil(BrowserSearchSettings.searchURL(
            fromTemplate: "file:///tmp/search?q={query}",
            query: "hello world"
        ))
        XCTAssertFalse(BrowserSearchSettings.isValidSearchURLTemplate("cmux://search?q={query}"))
    }

    func testCurrentSearchConfigurationUsesCustomProvider() throws {
        let suiteName = "BrowserSearchEngineTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(BrowserSearchEngine.custom.rawValue, forKey: BrowserSearchSettings.searchEngineKey)
        defaults.set("Kagi Fast", forKey: BrowserSearchSettings.customSearchEngineNameKey)
        defaults.set("https://kagi.com/search?q={query}", forKey: BrowserSearchSettings.customSearchEngineURLTemplateKey)

        let configuration = BrowserSearchSettings.currentConfiguration(defaults: defaults)
        let url = try XCTUnwrap(configuration.searchURL(query: "swift actors"))

        XCTAssertEqual(configuration.displayName, "Kagi Fast")
        XCTAssertEqual(configuration.remoteSuggestionsEngine, nil)
        XCTAssertEqual(url.host, "kagi.com")
        XCTAssertTrue(url.absoluteString.contains("q=swift%20actors"))
    }

    func testCurrentSearchConfigurationFallsBackForInvalidCustomURLTemplate() throws {
        let configuration = BrowserSearchSettings.configuration(
            engineRaw: BrowserSearchEngine.custom.rawValue,
            customName: "",
            customURLTemplate: "ftp://search.example.test?q={query}"
        )
        let url = try XCTUnwrap(configuration.searchURL(query: "swift actors"))

        XCTAssertEqual(configuration.displayName, BrowserSearchEngine.custom.displayName)
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertTrue(url.absoluteString.contains("q=swift%20actors"))
    }

    func testStaleRemoteSuggestionsSuppressedWhenProviderDoesNotSupportRemoteSuggestions() {
        let suggestions = staleOmnibarRemoteSuggestionsForDisplay(
            query: "swift",
            previousRemoteQuery: "swi",
            previousRemoteSuggestions: ["swift actors"],
            allowsRemoteSuggestions: false
        )

        XCTAssertTrue(suggestions.isEmpty)
    }
}


final class BrowserSearchSettingsTests: XCTestCase {
    func testCurrentSearchSuggestionsEnabledDefaultsToTrueWhenUnset() {
        let suiteName = "BrowserSearchSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.removeObject(forKey: BrowserSearchSettings.searchSuggestionsEnabledKey)
        XCTAssertTrue(BrowserSearchSettings.currentSearchSuggestionsEnabled(defaults: defaults))
    }

    func testCurrentSearchSuggestionsEnabledHonorsExplicitValue() {
        let suiteName = "BrowserSearchSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(false, forKey: BrowserSearchSettings.searchSuggestionsEnabledKey)
        XCTAssertFalse(BrowserSearchSettings.currentSearchSuggestionsEnabled(defaults: defaults))

        defaults.set(true, forKey: BrowserSearchSettings.searchSuggestionsEnabledKey)
        XCTAssertTrue(BrowserSearchSettings.currentSearchSuggestionsEnabled(defaults: defaults))
    }
}


