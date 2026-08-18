import Darwin
import Foundation
import Testing

/// Regression coverage for `cmux ssh-session-attach --session-id <id>` accepting
/// any session id without validation and attaching in the *caller's* workspace.
///
/// Repro: a user ran `cmux ssh-session-attach --session-id 10` from a local
/// (non-remote) workspace. `10` is not a session id at all — real ids look like
/// `ssh-<workspaceUUID>-<panelUUID>` and are listed by
/// `cmux ssh-session-list --all-workspaces`. The CLI still created a surface in
/// the caller's workspace whose startup wrapper runs
/// `ssh-pty-attach --wait --require-existing --session-id 10`, so
/// `workspace.remote.pty_bridge` parked for up to 185s waiting for a remote
/// daemon that can never exist there, inside the unbounded
/// `SSHPTYAttachRetryScriptBuilder` loop — a permanently hung pane.
///
/// These tests drive the real bundled CLI against a mock control socket and
/// assert on the exact v2 requests it emits, so they cover the observable
/// behavior (which methods run, with which params) rather than the source shape.
///
/// Gated by the dedicated non-tolerant focused CI step ("Run ssh-session-attach
/// anchor regression"): the sharded unit-test run tolerates any failure summary
/// reporting "(0 unexpected)", so a failing test there cannot red the shard.
@Suite(.serialized)
struct CLISSHSessionAttachSessionValidationTests {
    /// The exact user repro: a bogus session id must fail fast and create nothing.
    @Test func bogusSessionIDFailsWithoutCreatingAnySurface() throws {
        let (requests, result) = try runSSHSessionAttach(
            arguments: [
                "ssh-session-attach",
                "--session-id", "10",
                "--focus", "false",
            ]
        )

        #expect(result.status != 0, Comment(rawValue: result.stdout + result.stderr))
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(
            !methods.contains("surface.create"),
            Comment(rawValue: "bogus session id created a surface: \(methods.joined(separator: ","))")
        )
        #expect(
            !methods.contains("surface.split"),
            Comment(rawValue: "bogus session id split a surface: \(methods.joined(separator: ","))")
        )
        #expect(
            result.stderr.contains("ssh-session-list"),
            Comment(rawValue: result.stderr)
        )
    }

    /// A bogus session id must not be smuggled through by an explicit workspace.
    @Test func bogusSessionIDWithExplicitWorkspaceFailsWithoutCreatingAnySurface() throws {
        let (requests, result) = try runSSHSessionAttach(
            arguments: [
                "ssh-session-attach",
                "--session-id", "10",
                "--workspace", Self.remoteWorkspaceId,
                "--focus", "false",
            ]
        )

        #expect(result.status != 0, Comment(rawValue: result.stdout + result.stderr))
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(!methods.contains("surface.create"), Comment(rawValue: methods.joined(separator: ",")))
        #expect(!methods.contains("surface.split"), Comment(rawValue: methods.joined(separator: ",")))
    }

    /// A valid session id resolves to the workspace that owns it, not the
    /// caller's `CMUX_WORKSPACE_ID`.
    @Test func validSessionAttachesInOwningWorkspaceNotCallerWorkspace() throws {
        let (requests, result) = try runSSHSessionAttach(
            arguments: [
                "ssh-session-attach",
                "--session-id", Self.remoteSessionId,
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.stdout + result.stderr))
        let create = try #require(
            requests.last(where: { $0["method"] as? String == "surface.create" }),
            "expected a surface.create request"
        )
        let params = try #require(create["params"] as? [String: Any])
        #expect(
            params["workspace_id"] as? String == Self.remoteWorkspaceId,
            Comment(rawValue: "attached in \(params["workspace_id"] as? String ?? "nil")")
        )
        #expect(params["remote_pty_session_id"] as? String == Self.remoteSessionId)
        // applyFocusOption(defaultValue: true) semantics must be preserved.
        #expect(params["focus"] as? Bool == true)
    }

    /// `--focus false` still suppresses focus on the resolved owning workspace.
    @Test func validSessionHonorsExplicitFocusFalse() throws {
        let (requests, result) = try runSSHSessionAttach(
            arguments: [
                "ssh-session-attach",
                "--session-id", Self.remoteSessionId,
                "--focus", "false",
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.stdout + result.stderr))
        let create = try #require(requests.last(where: { $0["method"] as? String == "surface.create" }))
        let params = try #require(create["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == Self.remoteWorkspaceId)
        #expect(params["focus"] as? Bool == false)
    }

    /// Passing the owning workspace explicitly is accepted and used.
    @Test func explicitOwningWorkspaceIsAccepted() throws {
        let (requests, result) = try runSSHSessionAttach(
            arguments: [
                "ssh-session-attach",
                "--session-id", Self.remoteSessionId,
                "--workspace", Self.remoteWorkspaceId,
                "--focus", "false",
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.stdout + result.stderr))
        let create = try #require(requests.last(where: { $0["method"] as? String == "surface.create" }))
        let params = try #require(create["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == Self.remoteWorkspaceId)
    }

    /// `ssh-session-list --all-workspaces` prints the owning workspace as a
    /// `workspace:<n>` ref, so passing that ref back as `--workspace` must be
    /// accepted even though the session record's `workspace_id` is a UUID.
    @Test func explicitOwningWorkspaceRefIsAccepted() throws {
        let (requests, result) = try runSSHSessionAttach(
            arguments: [
                "ssh-session-attach",
                "--session-id", Self.remoteSessionId,
                "--workspace", Self.remoteWorkspaceRef,
                "--focus", "false",
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.stdout + result.stderr))
        let create = try #require(requests.last(where: { $0["method"] as? String == "surface.create" }))
        let params = try #require(create["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == Self.remoteWorkspaceId)
    }

    /// An explicit `--workspace` that does not own the session is an error in
    /// both directions: the CLI must neither silently override the user nor
    /// attach into the wrong workspace.
    @Test func explicitNonOwningWorkspaceFailsWithoutCreatingAnySurface() throws {
        let (requests, result) = try runSSHSessionAttach(
            arguments: [
                "ssh-session-attach",
                "--session-id", Self.remoteSessionId,
                "--workspace", Self.callerWorkspaceId,
                "--focus", "false",
            ]
        )

        #expect(result.status != 0, Comment(rawValue: result.stdout + result.stderr))
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(!methods.contains("surface.create"), Comment(rawValue: methods.joined(separator: ",")))
        #expect(!methods.contains("surface.split"), Comment(rawValue: methods.joined(separator: ",")))
    }

    /// An explicit `--surface` outside the owning workspace must be rejected
    /// instead of anchoring the split somewhere the session cannot live.
    @Test func explicitSurfaceOutsideOwningWorkspaceFailsWithoutSplitting() throws {
        let (requests, result) = try runSSHSessionAttach(
            arguments: [
                "ssh-session-attach",
                "--session-id", Self.remoteSessionId,
                "--split", "right",
                "--surface", Self.foreignSurfaceId,
                "--focus", "false",
            ]
        )

        #expect(result.status != 0, Comment(rawValue: result.stdout + result.stderr))
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(!methods.contains("surface.split"), Comment(rawValue: methods.joined(separator: ",")))
        #expect(!methods.contains("surface.create"), Comment(rawValue: methods.joined(separator: ",")))
    }

    /// An explicit `--surface` inside the owning workspace still anchors the split.
    @Test func explicitSurfaceInsideOwningWorkspaceSplitsThere() throws {
        let (requests, result) = try runSSHSessionAttach(
            arguments: [
                "ssh-session-attach",
                "--session-id", Self.remoteSessionId,
                "--split", "right",
                "--surface", Self.remoteSurfaceId,
                "--focus", "false",
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.stdout + result.stderr))
        let split = try #require(requests.last(where: { $0["method"] as? String == "surface.split" }))
        let params = try #require(split["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == Self.remoteWorkspaceId)
        #expect(params["surface_id"] as? String == Self.remoteSurfaceId)
        #expect(params["direction"] as? String == "right")
    }

    /// An explicit `--pane` outside the owning workspace must be rejected.
    @Test func explicitPaneOutsideOwningWorkspaceFailsWithoutCreatingAnySurface() throws {
        let (requests, result) = try runSSHSessionAttach(
            arguments: [
                "ssh-session-attach",
                "--session-id", Self.remoteSessionId,
                "--pane", Self.foreignPaneId,
                "--focus", "false",
            ]
        )

        #expect(result.status != 0, Comment(rawValue: result.stdout + result.stderr))
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(!methods.contains("surface.create"), Comment(rawValue: methods.joined(separator: ",")))
    }

    /// An explicit `--pane` inside the owning workspace still targets that pane.
    @Test func explicitPaneInsideOwningWorkspaceCreatesThere() throws {
        let (requests, result) = try runSSHSessionAttach(
            arguments: [
                "ssh-session-attach",
                "--session-id", Self.remoteSessionId,
                "--pane", Self.remotePaneId,
                "--focus", "false",
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.stdout + result.stderr))
        let create = try #require(requests.last(where: { $0["method"] as? String == "surface.create" }))
        let params = try #require(create["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == Self.remoteWorkspaceId)
        #expect(params["pane_id"] as? String == Self.remotePaneId)
    }

    /// The caller's `CMUX_SURFACE_ID` may only anchor a split when the caller's
    /// own workspace is the one that owns the session.
    @Test func callerEnvSurfaceIsNotUsedWhenSessionLivesElsewhere() throws {
        let (requests, result) = try runSSHSessionAttach(
            arguments: [
                "ssh-session-attach",
                "--session-id", Self.remoteSessionId,
                "--split", "right",
                "--focus", "false",
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.stdout + result.stderr))
        let split = try #require(requests.last(where: { $0["method"] as? String == "surface.split" }))
        let params = try #require(split["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == Self.remoteWorkspaceId)
        #expect(
            params["surface_id"] == nil,
            Comment(rawValue: "leaked caller surface anchor: \(params["surface_id"] ?? "nil")")
        )
    }

    // MARK: - Harness

    /// Runs the bundled CLI against a mock control socket that models one remote
    /// workspace owning `remoteSessionId` plus a local caller workspace with no
    /// persisted sessions.
    private func runSSHSessionAttach(
        arguments: [String]
    ) throws -> ([[String: Any]], ProcessRunResult) {
        let socketPath = Self.makeSocketPath("ssh-valid")
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = ServerState()
        let handled = Self.startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.remote.pty_sessions":
                return Self.v2Response(id: id, ok: true, result: [
                    "all_workspaces": true,
                    "workspace_count": 1,
                    "sessions": [Self.remoteSessionPayload],
                    "errors": [[String: Any]](),
                ])
            case "surface.list":
                let workspaceId = params["workspace_id"] as? String
                let surfaces: [[String: Any]] = workspaceId == Self.remoteWorkspaceId
                    ? [["id": Self.remoteSurfaceId, "ref": "surface:7", "index": 1]]
                    : []
                return Self.v2Response(id: id, ok: true, result: ["surfaces": surfaces])
            case "pane.list":
                let workspaceId = params["workspace_id"] as? String
                let panes: [[String: Any]] = workspaceId == Self.remoteWorkspaceId
                    ? [["id": Self.remotePaneId, "ref": "pane:4", "index": 1]]
                    : []
                return Self.v2Response(id: id, ok: true, result: ["panes": panes])
            case "surface.create", "surface.split":
                return Self.v2Response(id: id, ok: true, result: [
                    "workspace_id": params["workspace_id"] as? String ?? Self.remoteWorkspaceId,
                    "surface_id": "66666666-6666-6666-6666-666666666666",
                    "surface_ref": "surface:9",
                    "pane_id": "77777777-7777-7777-7777-777777777777",
                    "pane_ref": "pane:3",
                ])
            default:
                return Self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": method]
                )
            }
        }

        let result = Self.runProcess(
            executablePath: try Self.bundledCLIPath(),
            arguments: arguments,
            environment: cliEnvironment(socketPath: socketPath),
            timeout: 60
        )

        #expect(handled.wait(timeout: .now() + 60) == .success)
        #expect(state.errorsSnapshot().isEmpty, Comment(rawValue: state.errorsSnapshot().joined(separator: "\n")))
        #expect(!result.timedOut, Comment(rawValue: result.stderr))

        return (try state.requestObjects(), result)
    }

    private func cliEnvironment(socketPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment.removeValue(forKey: "CMUX_SOCKET_PASSWORD")
        environment.removeValue(forKey: "CMUX_WINDOW_ID")
        // The caller sits in a local workspace with no persisted SSH sessions,
        // exactly as in the reported repro.
        environment["CMUX_WORKSPACE_ID"] = Self.callerWorkspaceId
        environment["CMUX_SURFACE_ID"] = Self.callerSurfaceId
        return environment
    }

    private static let callerWorkspaceId = "11111111-1111-1111-1111-111111111111"
    private static let callerSurfaceId = "22222222-2222-2222-2222-222222222222"
    private static let remoteWorkspaceId = "44444444-4444-4444-4444-444444444444"
    private static let remoteWorkspaceRef = "workspace:4"
    private static let remoteWindowId = "33333333-3333-3333-3333-333333333333"
    private static let remoteSurfaceId = "55555555-5555-5555-5555-555555555555"
    private static let remotePaneId = "88888888-8888-8888-8888-888888888888"
    private static let foreignSurfaceId = "99999999-9999-9999-9999-999999999999"
    private static let foreignPaneId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private static let remoteSessionId = "ssh-44444444444444444444444444444444-abcdef0123456789"

    private static var remoteSessionPayload: [String: Any] {
        [
            "session_id": remoteSessionId,
            "window_id": remoteWindowId,
            "window_ref": "window:1",
            "workspace_id": remoteWorkspaceId,
            "workspace_ref": remoteWorkspaceRef,
            "workspace_title": "remote-box",
            "effective_cols": 120,
            "effective_rows": 40,
            "scrollback_bytes": 0,
            "attachments": [[String: Any]](),
        ]
    }

    private final class CLISSHSessionAttachSessionValidationBundleToken {}

    // Records socket callbacks from a background queue; `lock` guards both arrays.
    private final class ServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var requestLines: [String] = []
        private var errors: [String] = []

        func record(_ line: String) {
            lock.lock()
            requestLines.append(line)
            lock.unlock()
        }

        func recordError(_ message: String) {
            lock.lock()
            errors.append(message)
            lock.unlock()
        }

        func errorsSnapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return errors
        }

        func requestObjects() throws -> [[String: Any]] {
            lock.lock()
            let lines = requestLines
            lock.unlock()
            return try lines.map { line in
                try #require(CLISSHSessionAttachSessionValidationTests.jsonObject(line))
            }
        }
    }

    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private static func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: CLISSHSessionAttachSessionValidationBundleToken.self)
    }

    private static func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    private static func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG), userInfo: [
                NSLocalizedDescriptionKey: "Unix socket path is too long: \(path)",
            ])
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count {
                    buffer[index] = CChar(bitPattern: utf8[index])
                }
                buffer[utf8.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    private static func startMockServer(
        listenerFD: Int32,
        state: ServerState,
        handler: @escaping @Sendable (String) -> String
    ) -> DispatchSemaphore {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { handled.signal() }

            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                state.recordError("mock socket server failed to accept a client")
                return
            }
            defer { Darwin.close(clientFD) }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    state.recordError("mock socket server read failed with errno \(errno)")
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)

                while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                    pending.removeSubrange(0...newlineRange.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    state.record(line)
                    let response = handler(line) + "\n"
                    _ = response.withCString { pointer in
                        Darwin.write(clientFD, pointer, strlen(pointer))
                    }
                }
            }
        }
        return handled
    }

    private static func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    private static func malformedRequestResponse(id: String? = nil, raw: String) -> String {
        v2Response(
            id: id ?? "unknown",
            ok: false,
            error: ["code": "malformed_request", "message": "invalid or non-JSON payload", "raw": raw]
        )
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }
}
