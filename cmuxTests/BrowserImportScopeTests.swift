@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class BrowserImportScopeTests: XCTestCase {
    func testFromSelectionCookiesOnly() {
        let scope = BrowserImportScope.fromSelection(
            includeCookies: true,
            includeHistory: false,
            includeAdditionalData: false
        )
        XCTAssertEqual(scope, .cookiesOnly)
    }

    func testFromSelectionHistoryOnly() {
        let scope = BrowserImportScope.fromSelection(
            includeCookies: false,
            includeHistory: true,
            includeAdditionalData: false
        )
        XCTAssertEqual(scope, .historyOnly)
    }

    func testFromSelectionCookiesAndHistory() {
        let scope = BrowserImportScope.fromSelection(
            includeCookies: true,
            includeHistory: true,
            includeAdditionalData: false
        )
        XCTAssertEqual(scope, .cookiesAndHistory)
    }

    func testFromSelectionEverything() {
        let scope = BrowserImportScope.fromSelection(
            includeCookies: false,
            includeHistory: false,
            includeAdditionalData: true
        )
        XCTAssertEqual(scope, .everything)
    }

    func testFromSelectionRejectsEmptySelection() {
        let scope = BrowserImportScope.fromSelection(
            includeCookies: false,
            includeHistory: false,
            includeAdditionalData: false
        )
        XCTAssertNil(scope)
    }
}
