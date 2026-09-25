import Foundation
import Testing

@Suite(.serialized) struct CMUXCLIEventsStreamErrorTests: Sendable {
    /// Verifies that `cmux events` sanitizes a plain-text stream authorization response.
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

    /// Verifies that an unrelated plain-text stream error gets a generic diagnostic.
    @Test func testEventsCommandDoesNotMisclassifyPlainTextStreamError() throws {
        let support = CMUXCLIErrorOutputRegressionTests()
        let cliPath = try support.bundledCLIPath()
        let socketPath = "/tmp/cmux-events-stream-generic-error-\(UUID().uuidString).sock"
        let serverResponse = "ERROR: events.stream is unavailable"
        let expectedMessage = String(
            localized: "cli.events.error.server",
            defaultValue: "cmux returned an error while starting the event stream. Check the command and try again."
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
            !result.stderr.contains("Connection to cmux was denied"),
            Comment(rawValue: result.diagnostics)
        )
        #expect(
            responder.receivedRequests.contains { $0.contains("\"method\":\"events.stream\"") },
            Comment(rawValue: result.diagnostics)
        )
    }
}

extension CMUXCLIErrorOutputRegressionTests {
    /// Verifies that a socket policy rejection explains the external SSH workflow.
    @Test(arguments: [["ping"], ["capabilities"], ["ssh", "--no-focus", "example.invalid"]])
    func testSocketAccessDeniedExplainsExternalSSHWorkflow(arguments: [String]) throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-v2-access-denied-\(UUID().uuidString).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: "ERROR: Access denied - only processes started inside cmux can connect"
        )
        defer { responder.stop() }

        let result = runProcess(
            executablePath: cliPath,
            arguments: arguments,
            environment: [
                "PATH": "/usr/bin:/bin",
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        let expectedMessage = "cmux blocked this command before it ran. Run it from a cmux terminal, choose Automation mode in Settings > Automation > Socket Control Mode, or use an SSH link such as open -a cmux ssh://host from an external terminal."
        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 1, Comment(rawValue: result.diagnostics))
        #expect(result.stdout.isEmpty, Comment(rawValue: result.diagnostics))
        #expect(result.stderr == "Error: \(expectedMessage)\n", Comment(rawValue: result.diagnostics))
        #expect(!result.stderr.contains("only processes started inside cmux can connect"), Comment(rawValue: result.diagnostics))
        #expect(!responder.receivedRequests.isEmpty, Comment(rawValue: result.diagnostics))
    }
}
