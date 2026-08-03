import Darwin
import Foundation
import Testing

/// Regression coverage for GitHub issue #9191: `workspace create` has to hand
/// back the new workspace's UUID, because the input RPCs
/// (`surface.send_text`, `surface.send_key`, `workspace.prompt_submit`) key off
/// UUIDs and a short `workspace:N` ref is recyclable.
@Suite(.serialized)
struct CLIWorkspaceCreateIdentityTests {
    @Test("workspace create --json exposes the created workspace and surface UUIDs")
    func createJSONExposesUUIDs() async throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let result = try await run(
            command: [
                "workspace", "create",
                "--window", CLIWorkspaceCreateIdentityMockServer.windowID,
                "--name", "issue-repro",
                "--json",
            ],
            cliPath: cliPath,
            expectedRequestCount: 1
        )
        #expect(!result.process.timedOut, Comment(rawValue: result.process.stderr))
        #expect(result.process.status == 0, Comment(rawValue: result.process.stderr))

        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(result.process.stdout.utf8)) as? [String: Any],
            "Expected JSON object, got: \(result.process.stdout)"
        )
        #expect(
            payload["workspace_id"] as? String == CLIWorkspaceCreateIdentityMockServer.workspaceID,
            Comment(rawValue: "payload=\(payload)")
        )
        #expect(
            payload["surface_id"] as? String == CLIWorkspaceCreateIdentityMockServer.surfaceID,
            Comment(rawValue: "payload=\(payload)")
        )
        #expect(payload["workspace_ref"] as? String == CLIWorkspaceCreateIdentityMockServer.workspaceRef)
        #expect(payload["surface_ref"] as? String == CLIWorkspaceCreateIdentityMockServer.surfaceRef)
    }

    @Test("workspace create --command routes the initial command by UUID")
    func createCommandRoutesByUUID() async throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let result = try await run(
            command: [
                "workspace", "create",
                "--window", CLIWorkspaceCreateIdentityMockServer.windowID,
                "--name", "issue-repro",
                "--command", "echo hi",
            ],
            cliPath: cliPath,
            expectedRequestCount: 2
        )
        #expect(!result.process.timedOut, Comment(rawValue: result.process.stderr))
        #expect(result.process.status == 0, Comment(rawValue: result.process.stderr))

        #expect(result.requests.count == 2, Comment(rawValue: "requests=\(result.requests)"))
        let sendRequest = try #require(result.requests.last.flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        })
        #expect(sendRequest["method"] as? String == "surface.send_text")
        let params = try #require(sendRequest["params"] as? [String: Any])
        #expect(
            params["workspace_id"] as? String == CLIWorkspaceCreateIdentityMockServer.workspaceID,
            Comment(rawValue: "params=\(params)")
        )
    }

    private struct RunResult {
        let process: (status: Int32, stdout: String, stderr: String, timedOut: Bool)
        let requests: [String]
    }

    private func run(
        command: [String],
        cliPath: String,
        expectedRequestCount: Int
    ) async throws -> RunResult {
        let socketPath = Self.socketPath()
        let server = try CLIWorkspaceCreateIdentityMockServer(
            socketPath: socketPath,
            expectedRequestCount: expectedRequestCount
        )
        let requests = server.start()

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "2"
        let process = Self.runProcess(
            executablePath: cliPath,
            arguments: command,
            environment: environment
        )
        return RunResult(process: process, requests: await requests.value)
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) -> (status: Int32, stdout: String, stderr: String, timedOut: Bool) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // One-shot process completion signal; it does not guard mutable state.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return (-1, "", String(describing: error), false)
        }

        let timedOut = exited.wait(timeout: .now() + 5) == .timedOut
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }

        return (
            timedOut ? 124 : process.terminationStatus,
            String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            timedOut
        )
    }

    private static func socketPath() -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-wscreate-\(suffix).sock")
            .path
    }
}
