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

        let result = try runEventsCommand(support: support, cliPath: cliPath, socketPath: socketPath)

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

        let result = try runEventsCommand(support: support, cliPath: cliPath, socketPath: socketPath)

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

    /// Runs `cmux events` against `socketPath` from a throwaway home.
    ///
    /// The CLI reads the socket password file under `homeDirectoryForCurrentUser`
    /// (which honors `CFFIXED_USER_HOME`, not `HOME`). On a host whose own cmux
    /// set a socket password, a real home makes the CLI send `auth` first and
    /// print the responder's canned error verbatim before `events.stream` is
    /// ever requested, so the home must be hermetic.
    private func runEventsCommand(
        support: CMUXCLIErrorOutputRegressionTests,
        cliPath: String,
        socketPath: String
    ) throws -> CMUXCLIErrorOutputRegressionTests.ProcessRunResult {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let home = URL(fileURLWithPath: "/tmp/cmxh-\(shortID)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        var environment = BundledCLITestSupport.hermeticCLIEnvironment(
            home: home,
            base: ["PATH": "/usr/bin:/bin"]
        )
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        return support.runProcess(
            executablePath: cliPath,
            arguments: ["events", "--category", "workspace", "--after", "0", "--limit", "1"],
            environment: environment,
            timeout: 5
        )
    }
}
