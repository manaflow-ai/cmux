import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CLIWorkspaceStableIDTests {
    @Test("Workspace inspection JSON keeps mirror UUIDs by default")
    func workspaceInspectionJSONKeepsMirrorUUIDsByDefault() async throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let commands = [
            ["list-workspaces", "--window", Self.windowID, "--json"],
            ["workspace", "list", "--window", Self.windowID, "--json"],
            ["current-workspace", "--window", Self.windowID, "--json"],
            ["tree", "--window", Self.windowID, "--json"],
            ["top", "--window", Self.windowID, "--json"],
        ]

        for command in commands {
            let result = try await run(command: command, cliPath: cliPath)
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            let root = try responseObject(in: result.stdout)
            let workspace = try workspaceRow(in: root)
            #expect(workspace["id"] as? String == Self.workspaceID, Comment(rawValue: "command=\(command) row=\(workspace)"))
            #expect(workspace["ref"] as? String == "workspace:1", Comment(rawValue: "command=\(command) row=\(workspace)"))
            assertDefaultIdentifierShape(in: root, command: command)
        }
    }

    @Test("Explicit ID formats still shape workspace inspection JSON")
    func explicitIDFormatsStillShapeWorkspaceInspectionJSON() async throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let expectations: [(mode: String, hasID: Bool, hasRef: Bool)] = [
            ("refs", false, true),
            ("uuids", true, false),
            ("both", true, true),
        ]

        for expectation in expectations {
            let command = [
                "workspace", "list", "--window", Self.windowID, "--json",
                "--id-format", expectation.mode,
            ]
            let result = try await run(command: command, cliPath: cliPath)
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            let workspace = try workspaceRow(in: responseObject(in: result.stdout))
            #expect((workspace["id"] as? String) == (expectation.hasID ? Self.workspaceID : nil))
            #expect((workspace["ref"] as? String) == (expectation.hasRef ? "workspace:1" : nil))
        }
    }

    private func run(
        command: [String],
        cliPath: String
    ) async throws -> (status: Int32, stdout: String, stderr: String, timedOut: Bool) {
        let socketPath = Self.socketPath()
        let server = try CLIWorkspaceStableIDMockServer(
            socketPath: socketPath,
            windowID: Self.windowID,
            workspaceID: Self.workspaceID
        )
        let requests = server.start()

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "2"
        let result = Self.runProcess(
            executablePath: cliPath,
            arguments: command,
            environment: environment
        )
        let received = await requests.value
        #expect(received.count == 1, Comment(rawValue: "command=\(command) requests=\(received)"))
        return result
    }

    private func responseObject(in stdout: String) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any],
            "Expected JSON object, got: \(stdout)"
        )
    }

    private func workspaceRow(in root: [String: Any]) throws -> [String: Any] {
        if let workspace = (root["workspaces"] as? [[String: Any]])?.first {
            return workspace
        }
        if let workspace = root["workspace"] as? [String: Any] {
            return workspace
        }
        let window = try #require((root["windows"] as? [[String: Any]])?.first)
        return try #require((window["workspaces"] as? [[String: Any]])?.first)
    }

    private func assertDefaultIdentifierShape(in value: Any, command: [String]) {
        if let dictionary = value as? [String: Any] {
            if let ref = dictionary["ref"] as? String {
                let id = dictionary["id"] as? String
                if ref.hasPrefix("workspace:") {
                    #expect(id == Self.workspaceID, Comment(rawValue: "command=\(command) row=\(dictionary)"))
                } else {
                    #expect(id == nil, Comment(rawValue: "command=\(command) row=\(dictionary)"))
                }
            }
            for kind in ["window", "workspace", "pane", "surface"] where dictionary["\(kind)_ref"] != nil {
                let id = dictionary["\(kind)_id"] as? String
                if kind == "workspace" {
                    #expect(id == Self.workspaceID, Comment(rawValue: "command=\(command) row=\(dictionary)"))
                } else {
                    #expect(id == nil, Comment(rawValue: "command=\(command) row=\(dictionary)"))
                }
            }
            for child in dictionary.values {
                assertDefaultIdentifierShape(in: child, command: command)
            }
        } else if let array = value as? [Any] {
            for child in array {
                assertDefaultIdentifierShape(in: child, command: command)
            }
        }
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
            .appendingPathComponent("cli-wsid-\(suffix).sock")
            .path
    }

    private static let windowID = "11111111-1111-1111-1111-111111111111"
    private static let workspaceID = "22222222-2222-2222-2222-222222222222"
}
