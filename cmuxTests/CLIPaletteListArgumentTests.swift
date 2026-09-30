import Foundation
import Testing

/// What `cmux palette list` does with a `--window` value that is not one.
extension CMUXCLIErrorOutputRegressionTests {
    @Test func testPaletteListRejectsAFlagAsTheWindowValueBeforeAskingAWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-palette-window-\(UUID().uuidString.prefix(8)).sock"
        let listResponse = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "result": ["commands": [["id": "palette.newWorkspace", "title": "New Workspace", "enabled": true]]],
        ])
        let responder = try UnixSocketResponder(
            path: socketPath,
            // Consumed only by the buggy path, which swallows `--unknown` as the
            // window id and then lists a window the caller never named.
            response: String(decoding: listResponse, as: UTF8.self)
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        // The second `--window` is what makes this worth refusing: with the flag
        // swallowed as a value, the typed mistake disappears and the command
        // runs against window 1.
        let rejected = runProcess(
            executablePath: cliPath,
            arguments: ["palette", "list", "--window", "--unknown", "--window=1"],
            environment: environment,
            timeout: 5
        )
        XCTAssertFalse(rejected.timedOut, rejected.diagnostics)
        XCTAssertNotEqual(rejected.status, 0, rejected.diagnostics)
        XCTAssertTrue(
            rejected.stderr.contains("palette list: --window requires an id"),
            rejected.diagnostics
        )
        XCTAssertTrue(rejected.stdout.isEmpty, rejected.diagnostics)

        // `--window` last has always been a missing value; it still is, and by
        // the same sentence.
        let trailing = runProcess(
            executablePath: cliPath,
            arguments: ["palette", "list", "--window"],
            environment: environment,
            timeout: 5
        )
        XCTAssertNotEqual(trailing.status, 0, trailing.diagnostics)
        XCTAssertTrue(
            trailing.stderr.contains("palette list: --window requires an id"),
            trailing.diagnostics
        )

        XCTAssertEqual(
            responder.receivedRequests.count, 0,
            "A --window value that is a flag must be refused before any window is asked for palette rows"
        )
    }
}
