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


final class SidebarPathFormatterTests: XCTestCase {
    func testShortenedPathReplacesExactHomeDirectory() {
        XCTAssertEqual(
            SidebarPathFormatter.shortenedPath(
                "/Users/example",
                homeDirectoryPath: "/Users/example"
            ),
            "~"
        )
    }

    func testShortenedPathReplacesHomeDirectoryPrefix() {
        XCTAssertEqual(
            SidebarPathFormatter.shortenedPath(
                "/Users/example/projects/cmux",
                homeDirectoryPath: "/Users/example"
            ),
            "~/projects/cmux"
        )
    }

    func testShortenedPathLeavesExternalPathUnchanged() {
        XCTAssertEqual(
            SidebarPathFormatter.shortenedPath(
                "/tmp/cmux",
                homeDirectoryPath: "/Users/example"
            ),
            "/tmp/cmux"
        )
    }
}

