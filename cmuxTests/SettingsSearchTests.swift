import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SettingsSearchTests: XCTestCase {

    // MARK: - settingsSectionMatches

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(settingsSectionMatches(query: "", terms: ["Theme", "Language"]))
        XCTAssertTrue(settingsSectionMatches(query: "", terms: []))
    }

    func testWhitespaceOnlyQueryMatchesEverything() {
        XCTAssertTrue(settingsSectionMatches(query: "   ", terms: ["Theme"]))
    }

    func testExactMatchReturnsTrue() {
        XCTAssertTrue(settingsSectionMatches(query: "Theme", terms: ["Theme", "Language"]))
    }

    func testPartialMatchReturnsTrue() {
        XCTAssertTrue(settingsSectionMatches(query: "them", terms: ["Theme", "Language"]))
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertTrue(settingsSectionMatches(query: "THEME", terms: ["Theme"]))
        XCTAssertTrue(settingsSectionMatches(query: "theme", terms: ["THEME"]))
    }

    func testNoMatchReturnsFalse() {
        XCTAssertFalse(settingsSectionMatches(query: "browser", terms: ["Theme", "Language"]))
    }

    func testMatchesAgainstAnyTermInList() {
        XCTAssertTrue(settingsSectionMatches(query: "socket", terms: ["Automation", "Socket Control Mode", "Port Base"]))
    }

    func testLeadingAndTrailingWhitespaceInQueryIsIgnored() {
        XCTAssertTrue(settingsSectionMatches(query: "  theme  ", terms: ["Theme"]))
    }

    // MARK: - SettingsSection.searchTerms

    func testAllSectionsHaveNonEmptySearchTerms() {
        for section in SettingsSection.allCases {
            XCTAssertFalse(section.searchTerms.isEmpty, "\(section) has no search terms")
        }
    }

    func testAllSectionsHaveAtLeastThreeTerms() {
        for section in SettingsSection.allCases {
            XCTAssertGreaterThanOrEqual(
                section.searchTerms.count, 3,
                "\(section) has fewer than 3 search terms"
            )
        }
    }

    func testAllTermsAreNonEmpty() {
        for section in SettingsSection.allCases {
            for term in section.searchTerms {
                XCTAssertFalse(term.isEmpty, "\(section) contains an empty search term")
            }
        }
    }

    func testKeyboardShortcutsSectionIncludesActionLabels() {
        let terms = SettingsSection.keyboardShortcuts.searchTerms
        let actionLabels = KeyboardShortcutSettings.Action.allCases.map { $0.label }
        for label in actionLabels {
            XCTAssertTrue(terms.contains(label), "keyboardShortcuts missing action label: \(label)")
        }
    }
}
