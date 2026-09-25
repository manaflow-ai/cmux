import Darwin
import Foundation
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    /// `cmux notify --desktop false` must reach the app as `effects: {"desktop":
    /// false}` on the create request, the same shape a hook emits, and the key
    /// must stay absent when the caller did not pass the flag so the app keeps
    /// its policy default. The raw line is checked because a typed `Bool` read
    /// cannot tell JSON `false` from `0`.
    func testNotifyDesktopFlagTravelsAsAnEffectsOverride() throws {
        let socketPath = makeSocketPath("desktop")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let state = MockSocketServerState()
        startDetachedMockServer(listenerFD: listenerFD, state: state) { line in
            self.notifyMockResponse(line: line)
        }
        let cliPath = try bundledCLIPath()

        let disabled = runNotify(cliPath: cliPath, socketPath: socketPath, arguments: ["--title", "Panel only", "--desktop", "false"])
        XCTAssertEqual(disabled.status, 0, disabled.stderr + disabled.stdout)
        let disabledLine = try XCTUnwrap(createRequestLines(in: state).last, "no notification.create* request was sent")
        XCTAssertTrue(disabledLine.contains(#""effects":{"desktop":false}"#), disabledLine)
        XCTAssertTrue(disabledLine.contains(#""title":"Panel only""#), disabledLine)

        let inline = runNotify(cliPath: cliPath, socketPath: socketPath, arguments: ["--title", "Inline", "--desktop=true"])
        XCTAssertEqual(inline.status, 0, inline.stderr + inline.stdout)
        let inlineLine = try XCTUnwrap(createRequestLines(in: state).last)
        XCTAssertTrue(inlineLine.contains(#""effects":{"desktop":true}"#), inlineLine)

        let unchanged = runNotify(cliPath: cliPath, socketPath: socketPath, arguments: ["--title", "Default"])
        XCTAssertEqual(unchanged.status, 0, unchanged.stderr + unchanged.stdout)
        let defaultLine = try XCTUnwrap(createRequestLines(in: state).last)
        XCTAssertTrue(defaultLine.contains(#""title":"Default""#), defaultLine)
        XCTAssertFalse(defaultLine.contains(#""effects""#), "an absent flag must not send an effects override: \(defaultLine)")

        let requestsBeforeRejection = createRequestLines(in: state).count
        let rejected = runNotify(cliPath: cliPath, socketPath: socketPath, arguments: ["--title", "Bad", "--desktop", "maybe"])
        XCTAssertNotEqual(rejected.status, 0, "an unrecognizable --desktop value must be a usage error")
        XCTAssertTrue(rejected.stderr.contains("--desktop must be true|false"), rejected.stderr)
        XCTAssertEqual(createRequestLines(in: state).count, requestsBeforeRejection, "a rejected flag must not post anything")
    }

    /// Runs `cmux notify` with `arguments` against the mock socket, with a caller workspace and surface in the environment.
    private func runNotify(cliPath: String, socketPath: String, arguments: [String]) -> ProcessRunResult {
        runProcess(
            executablePath: cliPath,
            arguments: ["notify"] + arguments,
            environment: [
                "HOME": NSTemporaryDirectory(),
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 10
        )
    }

    /// The raw request lines of every `notification.create*` call the CLI sent, in order.
    private func createRequestLines(in state: MockSocketServerState) -> [String] {
        state.snapshot().filter { line in
            guard let payload = jsonObject(line), let method = payload["method"] as? String else { return false }
            return method.hasPrefix("notification.create")
        }
    }

    /// Answers every create request with a fixed delivery and every other request with an empty success.
    private func notifyMockResponse(line: String) -> String {
        guard let payload = jsonObject(line) else {
            return "OK"
        }
        guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
            return malformedRequestResponse(id: payload["id"] as? String, raw: line)
        }
        if method.hasPrefix("notification.create") {
            return v2Response(id: id, ok: true, result: [
                "workspace_id": "11111111-1111-1111-1111-111111111111",
                "surface_id": "22222222-2222-2222-2222-222222222222",
                "id": "33333333-3333-3333-3333-333333333333",
            ])
        }
        return v2Response(id: id, ok: true, result: [:])
    }
}
