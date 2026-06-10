import CmuxSocketControl
import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Browser download wait timeout
extension CMUXCLIErrorOutputRegressionTests {
    func testBrowserDownloadWaitUsesRequestedTimeoutForSocketResponse() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-dw-\(UUID().uuidString.prefix(8)).sock"
        let response = #"{"ok":true,"result":{"downloaded":true}}"#
        let responder = try UnixSocketResponder(path: socketPath, response: response, responseDelay: 0.4)
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "browser",
                UUID().uuidString,
                "download",
                "wait",
                "--timeout-ms",
                "1000",
            ],
            environment: environment,
            timeout: 3
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
    }

    func testBrowserDownloadWaitDefaultTimeoutMatchesServerDefaultWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-dw-\(UUID().uuidString.prefix(8)).sock"
        let response = #"{"ok":true,"result":{"downloaded":true}}"#
        let responder = try UnixSocketResponder(path: socketPath, response: response, responseDelay: 10.5)
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "browser",
                UUID().uuidString,
                "download",
                "wait",
            ],
            environment: environment,
            timeout: 16
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
    }

}
