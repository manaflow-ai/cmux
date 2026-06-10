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


final class TerminalOpenURLTargetResolutionTests: XCTestCase {
    func testResolvesHTTPSAsEmbeddedBrowser() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("https://example.com/path?q=1"))
        switch target {
        case let .embeddedBrowser(url):
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "example.com")
            XCTAssertEqual(url.path, "/path")
        default:
            XCTFail("Expected web URL to route to embedded browser")
        }
    }

    func testResolvesBareDomainAsEmbeddedBrowser() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("example.com/docs"))
        switch target {
        case let .embeddedBrowser(url):
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "example.com")
            XCTAssertEqual(url.path, "/docs")
        default:
            XCTFail("Expected bare domain to be normalized as an HTTPS browser URL")
        }
    }

    func testResolvesFileSchemeAsExternal() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("file:///tmp/cmux.txt"))
        switch target {
        case let .external(url):
            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(url.path, "/tmp/cmux.txt")
        default:
            XCTFail("Expected file URL to open externally")
        }
    }

    func testResolvesAbsolutePathAsExternalFileURL() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("/tmp/cmux-path.txt"))
        switch target {
        case let .external(url):
            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(url.path, "/tmp/cmux-path.txt")
        default:
            XCTFail("Expected absolute file path to open externally")
        }
    }

    func testResolvesNonWebSchemeAsExternal() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("mailto:test@example.com"))
        switch target {
        case let .external(url):
            XCTAssertEqual(url.scheme, "mailto")
        default:
            XCTFail("Expected non-web scheme to open externally")
        }
    }

    func testResolvesHostlessHTTPSAsExternal() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("https:///tmp/cmux.txt"))
        switch target {
        case let .external(url):
            XCTAssertEqual(url.scheme, "https")
            XCTAssertNil(url.host)
            XCTAssertEqual(url.path, "/tmp/cmux.txt")
        default:
            XCTFail("Expected hostless HTTPS URL to open externally")
        }
    }
}

