#if canImport(cmux_DEV)
@testable import cmux_DEV
import XCTest

final class CLIForwardingLaunchArgumentTests: XCTestCase {
    func testCliSubcommandsForwardToBundledCLI() {
        XCTAssertTrue(CLIForwardingLaunchRouter.shouldForwardToBundledCLI(arguments: ["cmux", "wait-for", "workspace:1"]))
        XCTAssertTrue(CLIForwardingLaunchRouter.shouldForwardToBundledCLI(arguments: ["cmux", "hooks", "setup"]))
    }

    func testGuiLaunchArgumentsStayInApp() {
        XCTAssertFalse(CLIForwardingLaunchRouter.shouldForwardToBundledCLI(arguments: ["cmux DEV", "DEV"]))
        XCTAssertFalse(CLIForwardingLaunchRouter.shouldForwardToBundledCLI(arguments: ["cmux", "-psn_0_12345"]))
        XCTAssertFalse(CLIForwardingLaunchRouter.shouldForwardToBundledCLI(arguments: ["cmux", "cmux://workspace/foo"]))
    }
}
#endif
