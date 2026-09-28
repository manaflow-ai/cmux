import Darwin
import Foundation
import Testing

/// Covers `cmux sessions live` end to end against a stub control socket.
///
/// The ordering and payload logic is unit-tested in `CmuxMobileHostTests`; what
/// only an end-to-end run can prove is that the CLI asks for the method the app
/// actually registers, preserves the order the app sent, and filters on the
/// state names that appear on the wire. A typo in any of those three would pass
/// every unit test and ship a broken command.
final class CLISessionsLiveTests {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var commands: [String] = []

        func append(_ command: String) {
            lock.lock()
            commands.append(command)
            lock.unlock()
        }
    }

    /// Three sessions, already in the attention order the app applies: a
    /// blocked one, a running one, then an idle one.
    private static func stubSessions() -> [[String: Any]] {
        [
            [
                "session_id": "sess-needs",
                "agent": "claude",
                "agent_name": "Claude",
                "state": "needs_input",
                "state_confirmed": true,
                "attention_rank": 0,
                "needs_attention": true,
                "state_since": "2026-09-28T09:00:00Z",
                "state_age_seconds": 720.0,
                "title": "Fix the parser",
                "cwd": "/Users/dev/Projects/cmux",
                "last_activity_at": "2026-09-28T09:00:00Z",
                "children_running": 0,
                "version": 4,
            ],
            [
                "session_id": "sess-work",
                "agent": "codex",
                "agent_name": "Codex",
                "state": "working",
                "state_confirmed": true,
                "attention_rank": 1,
                "needs_attention": false,
                "state_since": "2026-09-28T09:09:00Z",
                "state_age_seconds": 180.0,
                "title": "Add the usage dashboard",
                "cwd": "/Users/dev/Projects/notes",
                "last_activity_at": "2026-09-28T09:11:00Z",
                "children_running": 2,
                "version": 9,
            ],
            [
                "session_id": "sess-idle",
                "agent": "claude",
                "agent_name": "Claude",
                "state": "idle",
                "state_confirmed": false,
                "attention_rank": 2,
                "needs_attention": false,
                "last_activity_at": "2026-09-28T09:10:00Z",
                "children_running": 0,
                "version": 2,
            ],
        ]
    }

    private static func stubReply() -> [String: Any] {
        [
            "sessions": stubSessions(),
            "count": 3,
            "state_counts": ["needs_input": 1, "working": 1, "idle": 1, "ended": 0, "total": 3],
            "generated_at": "2026-09-28T09:12:00Z",
        ]
    }

    @Test func sessionsLiveRequestsTheRegistryAndKeepsItsOrder() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sessions-live")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            guard method == "agent.sessions.list" else {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": method])
            }
            return Self.v2Response(id: id, ok: true, result: Self.stubReply())
        }

        let result = runCLI(cliPath: cliPath, socketPath: socketPath, arguments: ["sessions", "live"])

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))

        // The CLI must ask for exactly the method the app registers.
        #expect(state.commands.compactMap { Self.v2Payload(from: $0)?["method"] as? String } == ["agent.sessions.list"])

        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "3 live agent sessions (1 needs input, 1 working)")

        // Order is the app's, not re-derived here: the CLI must not reshuffle it.
        let needsIndex = try #require(lines.firstIndex { $0.contains("sess-needs") })
        let workIndex = try #require(lines.firstIndex { $0.contains("sess-work") })
        let idleIndex = try #require(lines.firstIndex { $0.contains("sess-idle") })
        #expect(needsIndex < workIndex)
        #expect(workIndex < idleIndex)

        #expect(result.stdout.contains("needs_input"))
        #expect(result.stdout.contains("12m"))
        #expect(result.stdout.contains("Fix the parser"))
        #expect(result.stdout.contains("cwd=/Users/dev/Projects/cmux"))
        #expect(result.stdout.contains("subagents=2"))
        // The idle session was discovered without a hook confirming idleness.
        #expect(result.stdout.contains("state=unconfirmed"))
    }

    @Test func needsMeFiltersToBlockedSessionsAndRecountsThem() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sessions-needsme")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  payload["method"] as? String == "agent.sessions.list" else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            return Self.v2Response(id: id, ok: true, result: Self.stubReply())
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["sessions", "live", "--needs-me", "--json"]
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))

        let json = try #require(Self.v2Payload(from: result.stdout))
        let sessions = try #require(json["sessions"] as? [[String: Any]])
        #expect(sessions.count == 1)
        #expect(sessions.first?["session_id"] as? String == "sess-needs")
        #expect(json["count"] as? Int == 1)
        // Counts describe what was printed, not the unfiltered reply, and the
        // original total stays visible so the filter is not silently lossy.
        let counts = try #require(json["state_counts"] as? [String: Int])
        #expect(counts["needs_input"] == 1)
        #expect(counts["working"] == 0)
        #expect(counts["total"] == 1)
        #expect(json["matched_of_total"] as? Int == 3)
    }

    @Test func unknownStateIsRejectedWithoutContactingTheSocket() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sessions-badstate")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        // A live server is started so that a request WOULD be recorded; the
        // assertion below is only meaningful because something was listening.
        // Its semaphore is deliberately not awaited: nothing should connect, and
        // closing the listener in `defer` unblocks the accept.
        _ = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let id = Self.v2Payload(from: line)?["id"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            return Self.v2Response(id: id, ok: true, result: Self.stubReply())
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["sessions", "live", "--state", "blocked"]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status != 0)
        #expect(result.stderr.contains("unknown state"))
        // Argument validation happens before the socket is used, so a typo
        // never reaches the app.
        #expect(state.commands.isEmpty)
    }

    // MARK: - Harness

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    private func runCLI(
        cliPath: String,
        socketPath: String,
        arguments: [String],
        environmentOverrides: [String: String] = [:]
    ) -> ProcessRunResult {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        environmentOverrides.forEach { environment[$0.key] = $0.value }
        return runProcess(executablePath: cliPath, arguments: arguments, environment: environment, timeout: 15)
    }

    private func runProcess(
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
        process.terminationHandler = { _ in exitSignal.signal() }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: timedOut ? 124 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, maxPathLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: code)
        }

        return fd
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    private func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        handler: @escaping @Sendable (String) -> String
    ) -> DispatchSemaphore {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                handled.signal()
                return
            }
            defer {
                Darwin.close(clientFD)
                handled.signal()
            }
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
                pending.append(buffer, count: count)

                while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                    pending.removeSubrange(0...newlineRange.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    state.append(line)
                    guard writeAllToFixtureSocket(handler(line) + "\n", fd: clientFD) else { return }
                }
            }
        }
        return handled
    }

    private static func v2Payload(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
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
}
