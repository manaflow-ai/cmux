import XCTest

import CmuxFoundation

final class FileExplorerRootResolverTests: XCTestCase {

    // MARK: - Local home paths

    func testHomeDirectoryDisplaysAsTilde() {
        let result = "/Users/alice".homeRelativeDisplayPath(homePath: "/Users/alice")
        XCTAssertEqual(result, "~")
    }

    func testSubdirectoryOfHomeDisplaysWithTilde() {
        let result = "/Users/alice/Projects/myapp".homeRelativeDisplayPath(homePath: "/Users/alice")
        XCTAssertEqual(result, "~/Projects/myapp")
    }

    func testNonHomePathDisplaysVerbatim() {
        let result = "/var/log".homeRelativeDisplayPath(homePath: "/Users/alice")
        XCTAssertEqual(result, "/var/log")
    }

    func testNilHomePathReturnsFullPath() {
        let result = "/Users/alice/Documents".homeRelativeDisplayPath(homePath: nil)
        XCTAssertEqual(result, "/Users/alice/Documents")
    }

    func testEmptyHomePathReturnsFullPath() {
        let result = "/Users/alice/Documents".homeRelativeDisplayPath(homePath: "")
        XCTAssertEqual(result, "/Users/alice/Documents")
    }

    // MARK: - SSH home paths

    func testSSHHomePathDisplaysAsTilde() {
        let result = "/home/deploy".homeRelativeDisplayPath(homePath: "/home/deploy")
        XCTAssertEqual(result, "~")
    }

    func testSSHSubdirectoryDisplaysWithTilde() {
        let result = "/home/deploy/app/src".homeRelativeDisplayPath(homePath: "/home/deploy")
        XCTAssertEqual(result, "~/app/src")
    }

    func testSSHRootPathDisplaysVerbatim() {
        let result = "/etc/nginx".homeRelativeDisplayPath(homePath: "/root")
        XCTAssertEqual(result, "/etc/nginx")
    }

    // MARK: - Trailing slash normalization

    func testTrailingSlashOnHomeIsNormalized() {
        let result = "/Users/alice/".homeRelativeDisplayPath(homePath: "/Users/alice/")
        XCTAssertEqual(result, "~")
    }

    func testTrailingSlashOnPathIsNormalized() {
        let result = "/Users/alice/Documents/".homeRelativeDisplayPath(homePath: "/Users/alice")
        XCTAssertEqual(result, "~/Documents")
    }

    // MARK: - Edge cases

    func testSimilarPrefixDoesNotMatch() {
        // "/Users/alicex" should NOT match home="/Users/alice"
        let result = "/Users/alicex/Documents".homeRelativeDisplayPath(homePath: "/Users/alice")
        XCTAssertEqual(result, "/Users/alicex/Documents")
    }

    func testEmptyPathReturnsEmpty() {
        let result = "".homeRelativeDisplayPath(homePath: "/Users/alice")
        XCTAssertEqual(result, "")
    }
}
