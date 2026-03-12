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
        // .reset intentionally has only 2 terms (section header + reset action);
        // all other sections must have at least 3.
        let minimums: [SettingsSection: Int] = [.reset: 2]
        for section in SettingsSection.allCases {
            let minimum = minimums[section] ?? 3
            XCTAssertGreaterThanOrEqual(
                section.searchTerms.count, minimum,
                "\(section) has fewer than \(minimum) search terms"
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
