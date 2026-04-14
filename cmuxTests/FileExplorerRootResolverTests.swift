import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FileExplorerRootResolverTests: XCTestCase {

    // MARK: - Local home paths

    func testHomeDirectoryDisplaysAsTilde() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/Users/alice",
            homePath: "/Users/alice"
        )
        XCTAssertEqual(result, "~")
    }

    func testSubdirectoryOfHomeDisplaysWithTilde() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/Users/alice/Projects/myapp",
            homePath: "/Users/alice"
        )
        XCTAssertEqual(result, "~/Projects/myapp")
    }

    func testNonHomePathDisplaysVerbatim() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/var/log",
            homePath: "/Users/alice"
        )
        XCTAssertEqual(result, "/var/log")
    }

    func testNilHomePathReturnsFullPath() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/Users/alice/Documents",
            homePath: nil
        )
        XCTAssertEqual(result, "/Users/alice/Documents")
    }

    func testEmptyHomePathReturnsFullPath() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/Users/alice/Documents",
            homePath: ""
        )
        XCTAssertEqual(result, "/Users/alice/Documents")
    }

    // MARK: - SSH home paths

    func testSSHHomePathDisplaysAsTilde() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/home/deploy",
            homePath: "/home/deploy"
        )
        XCTAssertEqual(result, "~")
    }

    func testSSHSubdirectoryDisplaysWithTilde() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/home/deploy/app/src",
            homePath: "/home/deploy"
        )
        XCTAssertEqual(result, "~/app/src")
    }

    func testSSHRootPathDisplaysVerbatim() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/etc/nginx",
            homePath: "/root"
        )
        XCTAssertEqual(result, "/etc/nginx")
    }

    // MARK: - Trailing slash normalization

    func testTrailingSlashOnHomeIsNormalized() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/Users/alice/",
            homePath: "/Users/alice/"
        )
        XCTAssertEqual(result, "~")
    }

    func testTrailingSlashOnPathIsNormalized() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/Users/alice/Documents/",
            homePath: "/Users/alice"
        )
        XCTAssertEqual(result, "~/Documents")
    }

    // MARK: - Edge cases

    func testSimilarPrefixDoesNotMatch() {
        // "/Users/alicex" should NOT match home="/Users/alice"
        let result = FileExplorerRootResolver.displayPath(
            for: "/Users/alicex/Documents",
            homePath: "/Users/alice"
        )
        XCTAssertEqual(result, "/Users/alicex/Documents")
    }

    func testEmptyPathReturnsEmpty() {
        let result = FileExplorerRootResolver.displayPath(
            for: "",
            homePath: "/Users/alice"
        )
        XCTAssertEqual(result, "")
    }
}
