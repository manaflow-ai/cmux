import CmuxSocketControl
import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CMUXCLIErrorOutputRegressionTests: XCTestCase {
    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let timedOut: Bool
    }

    func testCLIErrorPathDoesNotCrashWhenStderrIsClosed() throws {
        let cliPath = try bundledCLIPath()
        let result = runShell(
            "CMUX_CLI_SENTRY_DISABLED=1 \(shellSingleQuote(cliPath)) definitely-not-a-command 2>&-",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(result.stdout.contains("Usage:"), result.stdout)
    }

    func testAgentTeamsHelpDoesNotLaunchExternalAgentCLI() throws {
        let cliPath = try bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["PATH"] = "/usr/bin:/bin"

        for command in ["claude-teams", "codex-teams"] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: [command, "--help"],
                environment: environment,
                timeout: 5
            )

            XCTAssertFalse(result.timedOut, result.stdout)
            XCTAssertEqual(result.status, 0, result.stdout)
            XCTAssertTrue(result.stdout.contains("Usage: cmux \(command)"), result.stdout)
            XCTAssertFalse(result.stdout.contains("Failed to launch"), result.stdout)
        }
    }

}

