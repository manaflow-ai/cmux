import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The one "Next:" line a bare `cmux vm` prints: on stderr, only for a person
/// at a terminal (forced here with `CMUX_CLI_HINTS=1`), never for `vm ls` or a
/// pipe, and off with `CMUX_NO_HINTS=1`. The table on stdout never changes.
extension CLINotifyProcessIntegrationRegressionTests {
    private func runVMListing(_ arguments: [String], hints: [String: String]) throws -> (stdout: String, stderr: String, status: Int32) {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-next-hint")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let handled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            guard method == "vm.list" else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": method])
            }
            return self.v2Response(id: id, ok: true, result: ["vms": [
                ["id": "vm-1", "displayName": "sleepy-owl", "status": "paused"],
                ["id": "vm-2", "displayName": "brave-otter", "status": "running"],
            ]])
        }
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-vm-hint-home-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment.removeValue(forKey: "CMUX_NO_HINTS")
        environment.removeValue(forKey: "CMUX_CLI_HINTS")
        environment.merge(hints) { _, new in new }
        let result = runProcess(executablePath: cliPath, arguments: arguments, environment: environment, timeout: 30)
        wait(for: [handled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        return (result.stdout, result.stderr, result.status)
    }

    func testBareVMSuggestsOpeningTheFirstRunningMachine() throws {
        let result = try runVMListing(["vm"], hints: ["CMUX_CLI_HINTS": "1"])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("brave-otter"), result.stdout)
        XCTAssertFalse(result.stdout.contains("Next:"), "stdout stays the table: \(result.stdout)")
        let nextLines = result.stderr.split(separator: "\n").filter { $0.hasPrefix("Next:") }
        XCTAssertEqual(nextLines.count, 1, result.stderr)
        XCTAssertTrue(nextLines.first?.contains("cmux vm open brave-otter") == true, result.stderr)
    }

    func testVMListAndPipesNeverPrintANextLine() throws {
        let listed = try runVMListing(["vm", "ls"], hints: ["CMUX_CLI_HINTS": "1"])
        XCTAssertEqual(listed.status, 0, listed.stderr)
        XCTAssertFalse(listed.stderr.contains("Next:"), listed.stderr)

        // The test runner's pipes are not a terminal.
        let piped = try runVMListing(["vm"], hints: [:])
        XCTAssertFalse(piped.stderr.contains("Next:"), piped.stderr)

        let off = try runVMListing(["vm"], hints: ["CMUX_CLI_HINTS": "1", "CMUX_NO_HINTS": "1"])
        XCTAssertFalse(off.stderr.contains("Next:"), off.stderr)
    }
}
