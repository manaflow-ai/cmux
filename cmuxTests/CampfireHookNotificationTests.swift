import Darwin
import Foundation
import Testing

// Serialized: every test here spawns hook subprocesses and binds a mock socket
// server, so running them concurrently starves each other's hooks into their
// 5s timeout. The failure looks like a product hang and is not one.
@Suite("Campfire hook notifications", .serialized)
struct CampfireHookNotificationTests {
    @Test func permissionNotificationLocalizesAndMarksNeedsInput() throws {
        let context = try makeHookContext(name: "campfire-permission-lifecycle")
        defer { context.cleanup() }

        let sessionId = "campfire-permission-session"
        let launchEnvironment = agentLaunchEnvironment(
            context: context,
            kind: "campfire",
            executable: "/usr/local/bin/campfire"
        )
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)

        let prompt = runAgentHook(
            context: context,
            agent: "campfire",
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
            extraEnvironment: launchEnvironment
        )
        #expect(prompt.timedOut == false, Comment(rawValue: prompt.stderr))
        #expect(prompt.status == 0, Comment(rawValue: prompt.stderr))

        let notificationStart = context.state.snapshot().count
        let notification = runAgentHook(
            context: context,
            agent: "campfire",
            subcommand: "notification",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"Notification","campfire_event_type":"permission.asked","display_name":"Alice","capability":"shell:exec"}"#,
            extraEnvironment: launchEnvironment
        )
        #expect(notification.timedOut == false, Comment(rawValue: notification.stderr))
        #expect(notification.status == 0, Comment(rawValue: notification.stderr))

        let notificationCommands = Array(context.state.snapshot().dropFirst(notificationStart))
        #expect(
            notificationCommands.contains {
                $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Campfire|Permission|Alice asked for permission to run a shell command|c=needs-permission;p=0")
            },
            "Campfire permission notification should be localized and notification-gated in Swift, saw \(notificationCommands)"
        )
        #expect(
            notificationCommands.contains {
                $0.hasPrefix("set_agent_lifecycle campfire needsInput --tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Campfire permission notification must mark the surface as needing input, saw \(notificationCommands)"
        )

        let stateURL = context.root.appendingPathComponent("campfire-hook-sessions.json")
        let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let sessions = try #require(state["sessions"] as? [String: Any])
        let record = try #require(sessions[sessionId] as? [String: Any])
        #expect(record["agentLifecycle"] as? String == "needsInput")
    }

    private final class BundleProbe {}

    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [String] = []

        func append(_ command: String) {
            lock.lock()
            commands.append(command)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            let value = commands
            lock.unlock()
            return value
        }
    }

    private struct HookContext {
        let cliPath: String
        let socketPath: String
        let listenerFD: Int32
        let state: MockSocketServerState
        let root: URL
        let workspaceId: String
        let surfaceId: String

        func cleanup() {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeHookContext(name: String) throws -> HookContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-\(name)-\(UUID().uuidString)", isDirectory: true)
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-\(name.prefix(6))-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).sock")
            .path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return HookContext(
            cliPath: try BundledCLITestSupport.bundledCLIPath(for: BundleProbe.self),
            socketPath: socketPath,
            listenerFD: try bindUnixSocket(at: socketPath),
            state: MockSocketServerState(),
            root: root,
            workspaceId: "11111111-1111-1111-1111-111111111111",
            surfaceId: "22222222-2222-2222-2222-222222222222"
        )
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "socket path is too long: \(path)",
            ])
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
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
            throw posixError("bind")
        }
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw posixError("listen")
        }
        return fd
    }

    private func agentLaunchEnvironment(
        context: HookContext,
        kind: String,
        executable: String,
        arguments: [String]? = nil
    ) -> [String: String] {
        [
            "CMUX_AGENT_LAUNCH_KIND": kind,
            "CMUX_AGENT_LAUNCH_EXECUTABLE": executable,
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(arguments ?? [executable]),
        ]
    }

    /// - Parameter timeout: seconds to wait for the hook subprocess. The default
    ///   matches the agents' own hook budget; raise it for tests that run many
    ///   hooks, where parallel suites can starve a healthy hook past 5s and the
    ///   timeout reads as a product hang.
    private func runAgentHook(
        context: HookContext,
        agent: String,
        subcommand: String,
        standardInput: String,
        extraEnvironment: [String: String] = [:],
        timeout: TimeInterval = 5
    ) -> ProcessRunResult {
        var environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": context.root.path,
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": context.surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": context.root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        environment.merge(extraEnvironment, uniquingKeysWith: { _, new in new })

        return runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", agent, subcommand],
            environment: environment,
            standardInput: standardInput,
            timeout: timeout
        )
    }

    private func startAgentHookMockServerAccepting(
        context: HookContext,
        connectionLimit: Int
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var accepted = 0
            while accepted < connectionLimit {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(context.listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    return
                }
                accepted += 1

                DispatchQueue.global(qos: .userInitiated).async {
                    defer { Darwin.close(clientFD) }
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
                            context.state.append(line)
                            let response = agentHookMockResponse(line: line, context: context) + "\n"
                            _ = response.withCString { ptr in
                                Darwin.write(clientFD, ptr, strlen(ptr))
                            }
                        }
                    }
                }
            }
        }
    }

    private func agentHookMockResponse(line: String, context: HookContext) -> String {
        guard let payload = jsonObject(line) else {
            return "OK"
        }
        guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
            return malformedRequestResponse(id: payload["id"] as? String, raw: line)
        }
        switch method {
        case "surface.list":
            return v2Response(
                id: id,
                ok: true,
                result: ["surfaces": [["id": context.surfaceId, "ref": "surface:1", "focused": true]]]
            )
        case "feed.push":
            return v2Response(id: id, ok: true, result: [:])
        case "surface.resume.set":
            return v2Response(id: id, ok: true, result: ["resume_binding": [:]])
        case "surface.resume.clear":
            return v2Response(id: id, ok: true, result: ["cleared": true])
        default:
            return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }
        stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
        try? stdinPipe.fileHandleForWriting.close()

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

    private func base64NULSeparated(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }

    private func v2Response(
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

    private func malformedRequestResponse(id: String? = nil, raw: String) -> String {
        v2Response(
            id: id ?? "unknown",
            ok: false,
            error: ["code": "malformed_request", "message": "invalid or non-JSON payload", "raw": raw]
        )
    }

    private func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private func posixError(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "\(operation) failed with errno \(errno)",
        ])
    }
}


/// Lives in this file (rather than its own suite) because the generic agent
/// hook harness above -- makeHookContext / runAgentHook / the mock socket
/// server -- is `private` to this type.
extension CampfireHookNotificationTests {
    /// One case per agent on the shared generic hook lane. Codex and grok carry
    /// extra special-casing in the notification handler, so they are exercised
    /// rather than assumed to behave like cursor.
    ///
    /// Grok takes the quota message specifically: its handler skips any
    /// notification whose classified status is nil, which is what quota text used
    /// to produce, so grok is where the quota cue interacts with agent-specific
    /// branching. The cue-to-status half of the mapping is covered exhaustively
    /// and cheaply by `AgentHookNotificationPolicyTests.classificationTable`;
    /// this test covers the status-to-lifecycle half, which is per-agent. Kept to
    /// one hook pair per agent because each pair is a subprocess plus a mock
    /// server, and a wider matrix starves itself under parallel suites.
    private static let genericLaneAgents = [
        ("cursor", "/usr/local/bin/cursor-agent"),
        ("codex", "/usr/local/bin/codex"),
        ("grok", "/usr/local/bin/grok"),
        ("kimi", "/usr/local/bin/kimi"),
    ]

    /// Both cues, for every agent. Quota is not merely a second spelling of
    /// "error": it reaches the lane through a different classifier branch, and
    /// grok's handler drops any alert whose classified status is nil — which is
    /// what quota text used to produce — so the two cues can fail independently
    /// per agent.
    private static let genericLaneCues = [
        "Build failed: exit 1",
        "usage limit reached",
    ]

    /// Drives one agent's prompt-submit + notification pair inside an existing
    /// context, returning only the commands the notification produced.
    ///
    /// Deliberately takes a shared context rather than making its own: every
    /// `HookContext` leaks a global-queue thread parked in `accept()` (closing
    /// the listener fd does not wake a blocked `accept()` on macOS), so a
    /// context-per-agent matrix starves the dispatch pool and random hooks then
    /// block on connect until they time out.
    private func genericNotificationCommands(
        context: HookContext,
        agent: String,
        executable: String,
        message: String
    ) -> [String] {
        let sessionId = "\(agent)-\(abs(message.hashValue))-lifecycle-session"
        let launchEnvironment = agentLaunchEnvironment(
            context: context,
            kind: agent,
            executable: executable
        )

        let submit = runAgentHook(
            context: context,
            agent: agent,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"go"}"#,
            extraEnvironment: launchEnvironment,
            timeout: 15
        )
        #expect(
            submit.timedOut == false,
            Comment(rawValue: "\(agent) prompt-submit timed out. stderr: \(submit.stderr)")
        )

        let notificationStart = context.state.snapshot().count
        let notification = runAgentHook(
            context: context,
            agent: agent,
            subcommand: "notification",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"Notification","message":"\#(message)"}"#,
            extraEnvironment: launchEnvironment,
            timeout: 15
        )
        #expect(
            notification.timedOut == false,
            Comment(rawValue: "\(agent) notification \"\(message)\" timed out. stderr: \(notification.stderr)")
        )
        return Array(context.state.snapshot().dropFirst(notificationStart))
    }

    /// An error or quota alert from any agent is the red `error` state, not the
    /// orange `needsInput` one. The notification lane painted a red pill but
    /// published `needsInput` alongside it, so an errored pane was
    /// indistinguishable from one waiting on an answer; quota text matched no
    /// error cue at all and classified as "waiting".
    @Test func errorAndQuotaNotificationsPublishTheErrorLifecycleForEveryAgent() throws {
        let context = try makeHookContext(name: "generic-error-lifecycle")
        defer { context.cleanup() }
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)

        for (agent, executable) in Self.genericLaneAgents {
            for message in Self.genericLaneCues {
            let commands = genericNotificationCommands(
                context: context,
                agent: agent,
                executable: executable,
                message: message
            )
            #expect(
                commands.contains { $0.hasPrefix("set_agent_lifecycle \(agent) error ") },
                "\(agent): \"\(message)\" must publish the error lifecycle, saw \(commands)"
            )
            #expect(
                !commands.contains { $0.hasPrefix("set_agent_lifecycle \(agent) needsInput ") },
                "\(agent): \"\(message)\" must not publish needsInput, saw \(commands)"
            )
            }
        }
    }

    /// cursor maps `beforeShellExecution` to prompt-submit and never emits a
    /// matching decrement, so a turn running two shell commands leaves the
    /// no-turn-id depth counter at +1 for good. Reporting that counter as
    /// "nested" used to suppress the stop lane's only `.idle` write, latching
    /// the pane on WORKING for the rest of the session.
    @Test func unbalancedPromptDepthStillReportsIdleOnStop() throws {
        let context = try makeHookContext(name: "generic-unbalanced-depth-idle")
        defer { context.cleanup() }

        let sessionId = "cursor-unbalanced-depth-session"
        let launchEnvironment = agentLaunchEnvironment(
            context: context,
            kind: "cursor",
            executable: "/usr/local/bin/cursor-agent"
        )
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)

        // Two prompt-submits, no intervening stop: depth drifts to 2.
        for index in 0..<2 {
            let submit = runAgentHook(
                context: context,
                agent: "cursor",
                subcommand: "prompt-submit",
                standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"step \#(index)"}"#,
                extraEnvironment: launchEnvironment
            )
            #expect(submit.timedOut == false, Comment(rawValue: submit.stderr))
            #expect(submit.status == 0, Comment(rawValue: submit.stderr))
        }

        let stopStart = context.state.snapshot().count
        let stop = runAgentHook(
            context: context,
            agent: "cursor",
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"Stop"}"#,
            extraEnvironment: launchEnvironment
        )
        #expect(stop.timedOut == false, Comment(rawValue: stop.stderr))
        #expect(stop.status == 0, Comment(rawValue: stop.stderr))

        let stopCommands = Array(context.state.snapshot().dropFirst(stopStart))
        #expect(
            stopCommands.contains {
                $0.hasPrefix("set_agent_lifecycle cursor idle --tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "A drifted prompt-depth counter must not suppress the stop lane's idle write, saw \(stopCommands)"
        )
    }
}
