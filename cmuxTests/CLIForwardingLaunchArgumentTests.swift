#if canImport(cmux_DEV)
@testable import cmux_DEV
import Foundation
import XCTest

final class CLIForwardingLaunchArgumentTests: XCTestCase {
    func testCliSubcommandsForwardToBundledCLI() {
        XCTAssertTrue(CLIForwardingLaunchRouter.shouldForwardToBundledCLI(arguments: ["cmux", "wait-for", "workspace:1"]))
        XCTAssertTrue(CLIForwardingLaunchRouter.shouldForwardToBundledCLI(arguments: ["cmux", "hooks", "setup"]))
    }

    func testGuiLaunchArgumentsStayInApp() {
        XCTAssertFalse(CLIForwardingLaunchRouter.shouldForwardToBundledCLI(arguments: ["cmux DEV", "DEV"]))
        XCTAssertFalse(CLIForwardingLaunchRouter.shouldForwardToBundledCLI(arguments: ["cmux STAGING", "STAGING"]))
        XCTAssertFalse(CLIForwardingLaunchRouter.shouldForwardToBundledCLI(arguments: ["cmux NIGHTLY", "NIGHTLY"]))
        XCTAssertFalse(CLIForwardingLaunchRouter.shouldForwardToBundledCLI(arguments: ["cmux", "-psn_0_12345"]))
        XCTAssertFalse(CLIForwardingLaunchRouter.shouldForwardToBundledCLI(arguments: ["cmux", "cmux://workspace/foo"]))
    }

    func testBundledCliResolverFallsBackToExecutablePath() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let appContentsURL = rootURL.appendingPathComponent("cmux DEV test.app/Contents", isDirectory: true)
        let macOSURL = appContentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesBinURL = appContentsURL.appendingPathComponent("Resources/bin", isDirectory: true)
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesBinURL, withIntermediateDirectories: true)

        let cliURL = resourcesBinURL.appendingPathComponent("cmux")
        XCTAssertTrue(fileManager.createFile(atPath: cliURL.path, contents: Data("#!/bin/sh\n".utf8)))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)

        let executableURL = macOSURL.appendingPathComponent("cmux DEV")
        let resolvedURL = CLIForwardingLaunchRouter.bundledCLIURL(
            bundle: Bundle(for: Self.self),
            fileManager: fileManager,
            executableURL: executableURL
        )

        XCTAssertEqual(resolvedURL?.standardizedFileURL.path, cliURL.standardizedFileURL.path)
    }
}
#endif
