import Foundation
import Testing
import XCTest

extension CMUXCLIErrorOutputRegressionTests {
    @Test func testEventsCommandSurfacesPlainTextStreamSocketError() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-events-stream-error-\(UUID().uuidString).sock"
        let accessDeniedMessage = "ERROR: Access denied - only processes started inside cmux can connect"
        let responder = try UnixSocketResponder(path: socketPath, response: accessDeniedMessage)
        defer { responder.stop() }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["events", "--category", "workspace", "--after", "0", "--limit", "1"],
            environment: [
                "PATH": "/usr/bin:/bin",
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 1, result.diagnostics)
        XCTAssertEqual(result.stdout, "", result.diagnostics)
        XCTAssertEqual(result.stderr, "Error: \(accessDeniedMessage)\n", result.diagnostics)
        XCTAssertFalse(result.stderr.contains("NSCocoaErrorDomain"), result.diagnostics)
        XCTAssertTrue(
            responder.receivedRequests.contains { $0.contains("\"method\":\"events.stream\"") },
            result.diagnostics
        )
    }
}
