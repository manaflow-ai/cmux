#if canImport(cmux_DEV)
@testable import cmux_DEV
import XCTest

final class CLIForwardingLaunchArgumentTests: XCTestCase {
    func testCliSubcommandsForwardToBundledCLI() {
        XCTAssertTrue(cmuxApp.shouldForwardToBundledCLI(arguments: ["cmux", "wait-for", "workspace:1"]))
        XCTAssertTrue(cmuxApp.shouldForwardToBundledCLI(arguments: ["cmux", "hooks", "setup"]))
    }

    func testGuiLaunchArgumentsStayInApp() {
        XCTAssertFalse(cmuxApp.shouldForwardToBundledCLI(arguments: ["cmux DEV", "DEV"]))
        XCTAssertFalse(cmuxApp.shouldForwardToBundledCLI(arguments: ["cmux", "-psn_0_12345"]))
        XCTAssertFalse(cmuxApp.shouldForwardToBundledCLI(arguments: ["cmux", "cmux://workspace/foo"]))
    }
}
#endif
