import XCTest
import Testing
import CmuxControlSocket
import CmuxTerminalCopyMode
import CmuxSocketControl
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import CMUXMobileCore
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class TerminalOpenURLSchemeGateTests: XCTestCase {
    func testRelativePathWithTrailingDotHasNoScheme() {
        XCTAssertNil(URL(string: "docs/specs/2026-05-22-test.md.")?.scheme)
    }

    func testBareDomainWithSlashHasNoScheme() {
        // resolveBrowserNavigableURL handles these, but they have no scheme
        XCTAssertNil(URL(string: "example.com/docs")?.scheme)
    }

    func testHTTPSURLHasScheme() {
        XCTAssertEqual(URL(string: "https://example.com/path")?.scheme, "https")
    }

    func testFileURLHasScheme() {
        XCTAssertEqual(URL(string: "file:///tmp/test.md")?.scheme, "file")
    }

    func testMailtoURLHasScheme() {
        XCTAssertEqual(URL(string: "mailto:test@example.com")?.scheme, "mailto")
    }

    func testAbsolutePathHasNoScheme() {
        // Absolute paths are filtered by isAbsolutePath before the scheme check,
        // but verify URL(string:) doesn't synthesize a scheme for them.
        XCTAssertNil(URL(string: "/tmp/test.md")?.scheme)
    }
}


