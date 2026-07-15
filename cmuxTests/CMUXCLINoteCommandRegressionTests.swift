import Foundation
import Testing
import XCTest

extension CMUXCLIErrorOutputRegressionTests {
    @Test func testNoteReadIgnoresInvalidAmbientSurfaceWhenWorkspaceIsAvailable() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-note-read-\(UUID().uuidString.prefix(8)).sock"
        let response = #"{"ok":true,"result":{"content":"agent note"}}"#
        let responder = try UnixSocketResponder(path: socketPath, response: response)
        defer { responder.stop() }

        let workspaceID = UUID().uuidString
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_WORKSPACE_ID"] = workspaceID
        environment["CMUX_SURFACE_ID"] = "not-a-surface-handle"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["note", "read", "todo"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout, "agent note")

        let request = try decodedSocketRequest(try XCTUnwrap(responder.receivedRequests.first))
        XCTAssertEqual(request["method"] as? String, "note.read")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["slug"] as? String, "todo")
        XCTAssertEqual(params["workspace_id"] as? String, workspaceID)
        #expect(params["surface_id"] == nil)
    }

    @Test func testNoteWriteRejectsUnknownFlagInPositionalContent() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-note-write-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: #"{"ok":true,"result":{}}"#)
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["note", "write", "todo", "hello", "--bad-flag"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stdout.contains("unknown flag '--bad-flag'"), result.stdout)
        XCTAssertEqual(responder.receivedRequests, [])
    }

    private func decodedSocketRequest(_ request: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any],
            request
        )
    }

}
