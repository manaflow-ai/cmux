import Darwin
import Foundation
import Testing

/// `cmux workspace env` positional handling, per issue #16145.
///
/// The command accepts at most one workspace handle (a positional or
/// `--workspace`). A second positional, or any positional alongside
/// `--workspace`, used to be silently dropped while the first handle was
/// queried — so a typo could report the wrong workspace and still exit 0.
/// These tests pin the refusal (non-zero exit, no `workspace.env` request)
/// and the still-working single-handle controls.
@Suite(.serialized)
struct CLIWorkspaceEnvPositionalTests {
    private static let timeout: TimeInterval = 60
    private static let callerWorkspaceID = "11111111-1111-1111-1111-111111111111"
    private static let explicitWorkspaceID = "22222222-2222-2222-2222-222222222222"
    private static let windowID = "33333333-3333-3333-3333-333333333333"

    // MARK: - Cases

    @Test func secondPositionalIsRefusedBeforeAnyRequest() throws {
        let run = try runWorkspaceEnv(arguments: ["workspace", "env", "workspace:1", "workspace:2"])

        #expect(run.result.status != 0)
        #expect(
            run.result.stderr.contains("unexpected argument"),
            Comment(rawValue: run.result.stderr + run.result.stdout))
        #expect(workspaceEnvRequest(run) == nil, "no workspace.env request may be sent")
    }

    @Test func strayPositionalAlongsideWorkspaceFlagIsRefused() throws {
        let run = try runWorkspaceEnv(
            arguments: ["workspace", "env", "--workspace", "workspace:1", "stray"])

        #expect(run.result.status != 0)
        #expect(
            run.result.stderr.contains("unexpected argument"),
            Comment(rawValue: run.result.stderr + run.result.stdout))
        #expect(workspaceEnvRequest(run) == nil, "no workspace.env request may be sent")
    }

    @Test func singlePositionalStillQueriesThatWorkspace() throws {
        let run = try runWorkspaceEnv(arguments: ["workspace", "env", "workspace:1"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let request = try #require(workspaceEnvRequest(run))
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == Self.explicitWorkspaceID)
    }

    @Test func workspaceFlagAloneStillQueriesThatWorkspace() throws {
        let run = try runWorkspaceEnv(
            arguments: ["workspace", "env", "--workspace", "workspace:1"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let request = try #require(workspaceEnvRequest(run))
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == Self.explicitWorkspaceID)
    }

    @Test func noHandleDefaultsToTheCallerWorkspace() throws {
        let run = try runWorkspaceEnv(arguments: ["workspace", "env"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let request = try #require(workspaceEnvRequest(run))
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == Self.callerWorkspaceID)
    }

    @Test func windowOptionValueIsNotTreatedAsPositional() throws {
        let run = try runWorkspaceEnv(
            arguments: ["workspace", "env", "--window", "1", "workspace:1"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let request = try #require(workspaceEnvRequest(run))
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["window_id"] as? String == Self.windowID)
        #expect(params["workspace_id"] as? String == Self.explicitWorkspaceID)
    }

    @Test func maskOptionValueIsNotTreatedAsPositional() throws {
        let run = try runWorkspaceEnv(
            arguments: ["workspace", "env", "workspace:1", "--mask"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let request = try #require(workspaceEnvRequest(run))
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == Self.explicitWorkspaceID)
        #expect(!run.result.stdout.contains("supersecret"))
        #expect(run.result.stdout.contains("API_TOKEN=su••••"))
    }

    @Test func unknownFlagIsRefusedBeforeAnyRequest() throws {
        let run = try runWorkspaceEnv(arguments: ["workspace", "env", "workspace:1", "--unknown"])

        #expect(run.result.status != 0)
        #expect(
            run.result.stderr.contains("unknown flag"),
            Comment(rawValue: run.result.stderr + run.result.stdout))
        #expect(workspaceEnvRequest(run) == nil, "no workspace.env request may be sent")
    }

    // MARK: - Harness

    /// Captures the CLI result and every socket request emitted by one invocation.
    private struct Run {
        let result: CLIHookProcessRunner.Result
        let requests: [[String: Any]]
    }

    /// Returns the first `workspace.env` request, if parsing and resolution reached the socket.
    private func workspaceEnvRequest(_ run: Run) -> [String: Any]? {
        run.requests.first { $0["method"] as? String == "workspace.env" }
    }

    private func runWorkspaceEnv(arguments: [String]) throws -> Run {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-workspace-env-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = makeCodexHookSocketPath("workspace-env")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let recorder = RequestRecorder()
        let server = Self.startMockServer(listenerFD: listenerFD, recorder: recorder)
        defer {
            server.stop.set()
            _ = server.done.wait(timeout: .now() + 5)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let result = CLIHookProcessRunner.run(
            executablePath: try BundledCLITestSupport.bundledCLIPath(for: CLITestBundleAnchor.self),
            arguments: arguments,
            environment: [
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_SOCKET_PASSWORD": "",
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_WORKSPACE_ID": Self.callerWorkspaceID,
                "CFFIXED_USER_HOME": home.path,
                "HOME": home.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            ],
            timeout: Self.timeout
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        return Run(result: result, requests: recorder.requests())
    }

    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func record(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        func requests() -> [[String: Any]] {
            lock.lock()
            let snapshot = lines
            lock.unlock()
            return snapshot.compactMap(codexHookJSONObject)
        }
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    /// Accepts clients until `stop` is set and answers every v2 request with
    /// a generic result. `workspace.env` tolerates a result without an `env`
    /// map (it prints "No environment variables" and exits 0), which is all
    /// the controls need; the refusal cases never get past parsing.
    private static func startMockServer(
        listenerFD: Int32,
        recorder: RequestRecorder
    ) -> (done: DispatchSemaphore, stop: StopFlag) {
        let done = DispatchSemaphore(value: 0)
        let stop = StopFlag()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { done.signal() }
            while !stop.isSet {
                var pollFD = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&pollFD, 1, 100)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                guard ready > 0 else { continue }
                let clientFD = Darwin.accept(listenerFD, nil, nil)
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    return
                }
                serve(clientFD: clientFD, recorder: recorder)
            }
        }
        return (done, stop)
    }

    private static func serve(clientFD: Int32, recorder: RequestRecorder) {
        defer { Darwin.close(clientFD) }
        guard ignoreSIGPIPE(onAcceptedFixtureSocket: clientFD) else { return }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            if count == 0 { return }
            pending.append(contentsOf: buffer.prefix(count))
            while let newline = pending.firstRange(of: Data([0x0A])) {
                let lineData = pending.subdata(in: 0..<newline.lowerBound)
                pending.removeSubrange(0...newline.lowerBound)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                recorder.record(line)
                let id = (codexHookJSONObject(line)?["id"] as? String) ?? "unknown"
                let method = codexHookJSONObject(line)?["method"] as? String
                var result: [String: Any] = ["deviceId": "33333333-3333-3333-3333-333333333333"]
                if method == "window.list" {
                    result["windows"] = [["id": Self.windowID, "ref": "window:1", "index": 1]]
                } else if method == "workspace.list" {
                    result["workspaces"] = [[
                        "id": Self.explicitWorkspaceID,
                        "ref": "workspace:1",
                        "index": 1,
                    ]]
                } else if method == "workspace.env" {
                    result["env"] = ["API_TOKEN": "supersecret"]
                }
                let response = codexHookV2Response(
                    id: id,
                    ok: true,
                    result: result
                )
                guard writeAllToFixtureSocket(response + "\n", fd: clientFD) else { return }
            }
        }
    }
}
