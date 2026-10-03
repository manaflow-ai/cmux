import CmuxFoundation
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Launches the shipped CLI. The socket peer records effects, so these tests
/// catch --here falling through to either workspace creation or the old local
/// shell/relay implementation instead of the native SSH owner.
@Suite(.serialized)
struct SSHHereCLIIntegrationTests {
    private typealias Harness = SSHStartupManualReconnectTests
    private final class BundleToken {}
    private static let workspaceID = "11111111-1111-1111-1111-111111111111"
    private static let surfaceID = "33333333-3333-3333-3333-333333333333"
    private static let operationID = "55555555-5555-5555-5555-555555555555"

    @Test("SSH --here sends the caller's exact workspace and surface to the native open")
    func hereUsesNativeOpenWithoutLegacyMutations() throws {
        let run = try Self.run(arguments: ["--here", "--name", "Remote here"])
        #expect(!run.result.timedOut)
        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(run.requests.compactMap { $0["method"] as? String } == [
            "workspace.ssh.open", "workspace.remote.status", "workspace.remote.status",
        ])
        let params = try #require(run.requests.first?["params"] as? [String: Any])
        #expect(params["here"] as? Bool == true)
        #expect(params["workspace_id"] as? String == Self.workspaceID)
        #expect(params["surface_id"] as? String == Self.surfaceID)
        #expect(params["destination"] as? String == "example.test")
        #expect(params["title"] as? String == "Remote here")
        #expect(params["focus"] as? Bool == false)
        #expect(params["terminal_startup_command"] == nil)
        #expect(params["relay_token"] == nil)
        let response = try #require(Harness.jsonObject(run.result.stdout))
        #expect(response["workspace_id"] as? String == Self.workspaceID)
    }

    @Test("SSH here defaults to focus and honors an explicit no-focus flag", arguments: [true, false])
    func hereRetainsSSHFocusPolicy(focus: Bool) throws {
        // The harness launches a non-TTY CLI. SSH still defaults to focus;
        // generic script/agent opening defaults must not override that policy.
        let run = try Self.run(arguments: ["--here"], focusArguments: focus ? [] : ["--no-focus"])
        #expect(!run.result.timedOut)
        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        let open = try #require(run.requests.first { $0["method"] as? String == "workspace.ssh.open" })
        let params = try #require(open["params"] as? [String: Any])
        #expect(params["focus"] as? Bool == focus)
        #expect(params["here"] as? Bool == true)
        #expect(params["workspace_id"] as? String == Self.workspaceID)
        #expect(params["surface_id"] as? String == Self.surfaceID)
    }

    @Test("SSH here keeps the invoking shell blocked until its own remote visit ends")
    func callerCannotContinueInParkedLocalShell() throws {
        let run = try Self.run(arguments: ["--here"], exerciseShellContinuation: true)
        #expect(!run.result.timedOut)
        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(run.requests.compactMap { $0["method"] as? String } == [
            "workspace.ssh.open", "workspace.remote.status",
        ])
    }

    @Test("Losing the status socket cannot release the hidden local shell")
    func statusTransportFailureKeepsCallerBlockedUntilRestored() throws {
        let run = try Self.run(arguments: ["--here"], exerciseShellContinuation: true,
                               dropFirstStatusConnection: true)
        #expect(!run.result.timedOut)
        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(run.requests.compactMap { $0["method"] as? String } == [
            "workspace.ssh.open", "workspace.remote.status", "workspace.remote.status", "workspace.remote.status",
        ])
    }

    @Test("SSH --here requires valid caller IDs before contacting the app", arguments: [
        ["CMUX_WORKSPACE_ID": ""],
        ["CMUX_SURFACE_ID": ""],
        ["CMUX_WORKSPACE_ID": "not-a-uuid"],
        ["CMUX_SURFACE_ID": "not-a-uuid"],
    ])
    func rejectsMissingOrInvalidCallerIDs(overrides: [String: String]) throws {
        let run = try Self.run(arguments: ["--here"], environmentOverrides: overrides)
        #expect(!run.result.timedOut)
        #expect(run.result.status != 0)
        #expect(run.requests.isEmpty, "Invalid caller identity must not select or mutate any workspace")
        #expect((run.result.stdout + run.result.stderr).contains("--here"))
    }

    @Test("SSH --here rejects incompatible modes before contacting the app", arguments: [
        ["--window", "22222222-2222-2222-2222-222222222222"],
        ["-T"],
        ["--ssh-option", "RequestTTY=no"],
        ["--transport", "mosh"],
    ])
    func rejectsIncompatibleModes(arguments: [String]) throws {
        let run = try Self.run(arguments: ["--here"] + arguments)
        #expect(!run.result.timedOut)
        #expect(run.result.status != 0)
        #expect(run.requests.isEmpty, "An incompatible --here request must never enter the legacy SSH path")
        #expect((run.result.stdout + run.result.stderr).contains("--here"))
    }

    @Test("Plain SSH does not request an in-place visit")
    func plainSSHDoesNotBecomeHere() throws {
        let run = try Self.run(arguments: [])
        #expect(!run.result.timedOut)
        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        let opens = run.requests.filter { $0["method"] as? String == "workspace.ssh.open" }
        #expect(opens.count == 1)
        let params = try #require(opens.first?["params"] as? [String: Any])
        #expect(params["here"] as? Bool != true)
    }

    private struct Run {
        let result: Harness.ProcessRunResult
        let requests: [[String: Any]]
    }

    private static func run(
        arguments: [String],
        environmentOverrides: [String: String] = [:],
        exerciseShellContinuation: Bool = false,
        dropFirstStatusConnection: Bool = false,
        focusArguments: [String] = ["--no-focus"]
    ) throws -> Run {
        let cli = try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-here-cli-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketPath = Harness.makeSocketPath("ssh-here")
        let listenerFD = try Harness.bindUnixSocket(at: socketPath)
        let state = Harness.MockSocketServerState()
        let releaseStatus = DispatchSemaphore(value: 0)
        defer {
            releaseStatus.signal()
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        CLIMockAcceptLoopRegistry.shared.start(
            listenerFD: listenerFD,
            onConnection: { clientFD in
                defer { Darwin.close(clientFD) }
                cliMockServeLineFramedConnection(clientFD: clientFD) { line in
                    state.append(line)
                    guard let request = Harness.jsonObject(line),
                          let id = request["id"] as? String,
                          let method = request["method"] as? String else {
                        return Harness.malformedRequestResponse(raw: line)
                    }
                    if method == "workspace.remote.status" {
                        let params = request["params"] as? [String: Any]
                        #expect(params?["workspace_id"] as? String == workspaceID)
                        let statusCount = state.snapshot().compactMap(Harness.jsonObject).filter {
                            $0["method"] as? String == "workspace.remote.status"
                        }.count
                        if dropFirstStatusConnection && statusCount == 1 {
                            // EOF is an actual transport error, not a successful
                            // status response claiming the visit has finished.
                            Darwin.shutdown(clientFD, SHUT_RDWR)
                            return nil
                        }
                        if exerciseShellContinuation && (!dropFirstStatusConnection || statusCount >= 3) {
                            _ = releaseStatus.wait(timeout: .now() + 10)
                        }
                        let stillActive = dropFirstStatusConnection ? statusCount == 2
                            : !exerciseShellContinuation && statusCount == 1
                        let remote: [String: Any] = stillActive
                            ? ["enabled": true, "here_operation_id": operationID, "state": "connected"]
                            : ["enabled": false, "state": "disconnected"]
                        return Harness.v2Response(id: id, ok: true, result: ["remote": remote])
                    }
                    guard method == "workspace.ssh.open" else {
                        return Harness.v2Response(id: id, ok: false, error: [
                            "code": "unexpected_method", "message": "Unexpected method \(method)",
                        ])
                    }
                    var result: [String: Any] = [
                        "workspace_id": workspaceID,
                        "window_id": "22222222-2222-2222-2222-222222222222",
                        // The native remote panel is deliberately not the parked local panel.
                        "surface_id": "44444444-4444-4444-4444-444444444444",
                        "transport": "cmux-tui", "carrier": "ssh",
                    ]
                    if (request["params"] as? [String: Any])?["here"] as? Bool == true {
                        Self.expectLiveChildCaller(in: request)
                        result["here_operation_id"] = operationID
                    }
                    return Harness.v2Response(id: id, ok: true, result: result)
                }
            },
            onListenerClosed: {}
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_WORKSPACE_ID"] = workspaceID
        environment["CMUX_SURFACE_ID"] = surfaceID
        environment["HOME"] = root.path
        environment["CFFIXED_USER_HOME"] = root.path
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["XDG_DATA_HOME"] = root.appendingPathComponent("data").path
        environment["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        environment.merge(environmentOverrides) { _, value in value }
        if exerciseShellContinuation {
            let sentinel = root.appendingPathComponent("local-continuation")
            environment["CMUX_TEST_CLI"] = cli
            environment["CMUX_TEST_SENTINEL"] = sentinel.path
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "\"$CMUX_TEST_CLI\" --json --id-format uuids ssh --here --no-focus example.test && printf resumed > \"$CMUX_TEST_SENTINEL\""]
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            defer { Self.stopOwnedShell(process) }
            let expectedStatusCount = dropFirstStatusConnection ? 3 : 1
            func statusCount() -> Int {
                state.snapshot().compactMap(Harness.jsonObject).filter { $0["method"] as? String == "workspace.remote.status" }.count
            }
            let deadline = Date.now.addingTimeInterval(5)
            while process.isRunning, Date.now < deadline,
                  statusCount() < expectedStatusCount {
                RunLoop.current.run(until: Date.now.addingTimeInterval(0.01))
            }
            #expect(process.isRunning, "The shell must not resume while the remote visit is active")
            #expect(!FileManager.default.fileExists(atPath: sentinel.path),
                    "A chained local command must not run in the hidden original shell")
            #expect(statusCount() == expectedStatusCount)
            releaseStatus.signal()
            let exited = Self.waitForExit(process, timeout: 5)
            if !exited { Self.stopOwnedShell(process) }
            #expect(FileManager.default.fileExists(atPath: sentinel.path),
                    "The invoking shell should resume after that visit is finished")
            let result = Harness.ProcessRunResult(
                status: process.terminationStatus,
                stdout: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                stderr: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                timedOut: !exited
            )
            return Run(result: result, requests: state.snapshot().compactMap(Harness.jsonObject))
        }
        let result = Harness.runProcess(
            executablePath: cli,
            arguments: ["--json", "--id-format", "uuids", "ssh"] + focusArguments + ["example.test"] + arguments,
            environment: environment,
            timeout: 5
        )
        return Run(result: result, requests: state.snapshot().compactMap(Harness.jsonObject))
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while process.isRunning, Date.now < deadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.01))
        }
        if !process.isRunning { process.waitUntilExit(); return true }
        return false
    }

    private static func expectLiveChildCaller(in request: [String: Any]) {
        guard let params = request["params"] as? [String: Any],
              let caller = params["caller_process"] as? [String: Any],
              let pid = caller["pid"] as? Int,
              let rawPID = pid_t(exactly: pid),
              let seconds = caller["start_seconds"] as? Int64,
              let microseconds = caller["start_microseconds"] as? Int64,
              let identity = AgentPIDProcessIdentity(pid: rawPID) else {
            Issue.record("SSH here must send a live kernel process identity")
            return
        }
        #expect(identity.startSeconds == seconds)
        #expect(identity.startMicroseconds == microseconds)
        #expect(identity.pid != getpid(), "The owner must be the launched CLI, not its test harness")
        var ancestor = identity.pid
        for _ in 0..<8 {
            guard let parent = AgentPIDProcessIdentity.processSnapshot(pid: ancestor)?.parentPID else { break }
            ancestor = parent
            if ancestor == getpid() { break }
        }
        #expect(ancestor == getpid(), "The supplied identity must belong to this test's launched child")
    }

    private static func stopOwnedShell(_ process: Process) {
        guard process.isRunning else { return }
        // A broken wait loop can leave the CLI below /bin/sh. Reap only the
        // test-owned process tree before reading its inherited stdout pipes.
        let cleanup = SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction()
            + "\ncmux_ssh_terminate_auth_process_tree \(process.processIdentifier) \(getpid())"
        _ = Harness.runProcess(executablePath: "/bin/sh", arguments: ["-c", cleanup],
                               environment: ProcessInfo.processInfo.environment, timeout: 5)
        if !waitForExit(process, timeout: 1) {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
}
