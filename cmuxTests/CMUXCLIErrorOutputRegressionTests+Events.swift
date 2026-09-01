import Foundation
import Testing

@Suite(.serialized) struct CMUXCLIEventsStreamErrorTests: Sendable {
    @Test func testEventsCommandSanitizesPlainTextStreamSocketError() throws {
        let support = CMUXCLIErrorOutputRegressionTests()
        let cliPath = try support.bundledCLIPath()
        let socketPath = "/tmp/cmux-events-stream-error-\(UUID().uuidString).sock"
        let serverResponse = "ERROR: Access denied - only processes started inside cmux can connect"
        let expectedMessage = String(
            localized: "cli.events.error.connectionDenied",
            defaultValue: "Connection to cmux was denied. Run this command from a cmux terminal or review socket access in Settings > Automation."
        )
        let responder = try UnixSocketResponder(path: socketPath, response: serverResponse)
        defer { responder.stop() }

        let result = support.runProcess(
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

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 1, Comment(rawValue: result.diagnostics))
        #expect(result.stdout.isEmpty, Comment(rawValue: result.diagnostics))
        #expect(
            result.stderr == "Error: \(expectedMessage)\n",
            Comment(rawValue: result.diagnostics)
        )
        #expect(
            !result.stderr.contains(serverResponse),
            Comment(rawValue: result.diagnostics)
        )
        #expect(
            !result.stderr.contains("NSCocoaErrorDomain"),
            Comment(rawValue: result.diagnostics)
        )
        #expect(
            responder.receivedRequests.contains { $0.contains("\"method\":\"events.stream\"") },
            Comment(rawValue: result.diagnostics)
        )
    }
}
