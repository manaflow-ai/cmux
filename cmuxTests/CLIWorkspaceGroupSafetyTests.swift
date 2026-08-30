import Foundation
import Testing

@Suite(.serialized)
struct CLIWorkspaceGroupSafetyTests {
    @Test func bareCreateSendsAnExplicitEmptyMemberList() async throws {
        let request = try await run(["workspace", "group", "create", "--json"])
        let params = try requestParams(request, method: "workspace.group.create")

        #expect((params["child_workspace_ids"] as? [String]) == [])
    }

    @Test func workspaceCreateForwardsInitialCommand() async throws {
        let requests = try await runRequests(["workspace", "create", "--command", "echo hello", "--json"])
        #expect(requests.count == 1)
        #expect(requests.compactMap { $0["method"] as? String } == ["workspace.create"])
        #expect(!requests.contains { ($0["method"] as? String) == "surface.send_text" })

        let params = try requestParams(try #require(requests.first), method: "workspace.create")
        #expect(params["initial_command"] as? String == "echo hello")
    }

    @Test func legacyNewWorkspaceForwardsInitialCommand() async throws {
        let requests = try await runRequests(["new-workspace", "--command", "echo hello", "--json"])
        #expect(requests.count == 1)
        #expect(requests.compactMap { $0["method"] as? String } == ["workspace.create"])
        #expect(!requests.contains { ($0["method"] as? String) == "surface.send_text" })

        let params = try requestParams(try #require(requests.first), method: "workspace.create")
        #expect(params["initial_command"] as? String == "echo hello")
    }

    @Test func deleteDefaultsToNonDestructiveIntent() async throws {
        let request = try await run([
            "workspace", "group", "delete", "workspace_group:1", "--json",
        ])
        let params = try requestParams(request, method: "workspace.group.ungroup")

        #expect(params["group_id"] as? String == "workspace_group:1")
    }

    @Test func deleteForwardsExplicitDestructiveIntent() async throws {
        let request = try await run([
            "workspace", "group", "delete", "workspace_group:1",
            "--close-workspaces", "--json",
        ])
        let params = try requestParams(request, method: "workspace.group.delete")

        #expect(params["close_workspaces"] as? Bool == true)
    }

    @Test func deleteDoesNotTreatTokensAfterOptionTerminatorAsDestructiveIntent() async throws {
        let request = try await run([
            "workspace", "group", "delete", "workspace_group:1", "--",
            "--close-workspaces", "--json",
        ])
        let params = try requestParams(request, method: "workspace.group.ungroup")

        #expect(params["group_id"] as? String == "workspace_group:1")
    }

    private func run(_ arguments: [String]) async throws -> [String: Any] {
        try #require(try await runRequests(arguments).first)
    }

    private func runRequests(_ arguments: [String]) async throws -> [[String: Any]] {
        let socketPath = Self.socketPath()
        let server = try CLIWorkspaceGroupSafetyMockServer(socketPath: socketPath)
        let requestTask = server.start()

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "2"

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(
            fileURLWithPath: try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self)
        )
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { completedProcess in
                continuation.resume(returning: completedProcess.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        let output = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(status == 0, Comment(rawValue: output))

        let requestLines = await requestTask.value
        return try requestLines.map { line in
            try #require(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
        }
    }

    private func requestParams(
        _ request: [String: Any],
        method: String
    ) throws -> [String: Any] {
        #expect(request["method"] as? String == method)
        return try #require(request["params"] as? [String: Any])
    }

    private static func socketPath() -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-group-safety-\(suffix).sock")
            .path
    }

    private final class BundleToken {}
}
