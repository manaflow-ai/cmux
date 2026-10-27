import Darwin
import Foundation
import Testing

@Suite("Vault agent hooks")
struct VaultAgentHookTests {
    @Test func vaultAgentEventsJournalUnderTheirOwnId() throws {
        let context = try makeHookContext(name: "vault-agent-lifecycle")
        defer { context.cleanup() }

        let sessionId = "vault-agent-session"
        let launchEnvironment = agentLaunchEnvironment(
            context: context,
            kind: "myagent",
            executable: "/usr/local/bin/myagent"
        )
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)

        for (subcommand, input) in [
            ("session-start", #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#),
            ("prompt-submit", #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#),
            ("stop", #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"Done"}"#),
            ("prompt-submit", #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"run the tests"}"#),
            ("notification", #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"Notification","message":"Approve the shell command?","notification_type":"permission_prompt"}"#),
        ] {
            let result = runAgentHook(
                context: context,
                agent: "myagent",
                subcommand: subcommand,
                standardInput: input,
                extraEnvironment: launchEnvironment
            )
            #expect(result.timedOut == false, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: "\(subcommand): \(result.stderr)"))
        }

        let captures = AgentJournalAppendCapture.captures(in: context.state.snapshot())
        for kind in ["agent.session.started", "agent.turn.started", "agent.turn.completed", "agent.approval.requested"] {
            #expect(
                captures.contains { capture in
                    capture.kind == kind
                        && capture.agentKey == "myagent"
                        && capture.workspaceId == context.workspaceId
                        && capture.surfaceId == context.surfaceId
                },
                "A vault agent must journal \(kind) under its own id, saw \(captures.map(\.kind))"
            )
        }
        let stateURL = context.root.appendingPathComponent("myagent-hook-sessions.json")
        let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let sessions = try #require(state["sessions"] as? [String: Any])
        let record = try #require(sessions[sessionId] as? [String: Any])
        #expect(record["workspaceId"] as? String == context.workspaceId)
        #expect(record["surfaceId"] as? String == context.surfaceId)
        #expect(
            !context.state.snapshot().contains { $0.contains("surface.resume.") },
            "A vault agent resumes through its cmux.json resumeCommand, so hooks must not set or clear its binding"
        )
    }

    @Test func vaultAgentSessionEndLeavesTheResumeBinding() throws {
        let context = try makeHookContext(name: "vault-agent-session-end")
        defer { context.cleanup() }

        let sessionId = "vault-agent-ended-session"
        let launchEnvironment = agentLaunchEnvironment(
            context: context,
            kind: "myagent",
            executable: "/usr/local/bin/myagent"
        )
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)

        for subcommand in ["session-start", "session-end"] {
            let result = runAgentHook(
                context: context,
                agent: "myagent",
                subcommand: subcommand,
                standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)"}"#,
                extraEnvironment: launchEnvironment
            )
            #expect(result.status == 0, Comment(rawValue: "\(subcommand): \(result.stderr)"))
        }
        let commands = context.state.snapshot()
        #expect(commands.contains { $0.hasPrefix("clear_agent_pid ") }, "session-end must still run, saw \(commands)")
        #expect(
            !commands.contains { $0.contains("surface.resume.") },
            "Vault restores this agent from its own binding, so session-end must not clear it"
        )
    }

    @Test func vaultAgentTargetsInstallNothing() throws {
        let context = try makeHookContext(name: "vault-agent-install")
        defer { context.cleanup() }

        let result = runAgentHook(context: context, agent: "myagent", subcommand: "install", standardInput: "")
        #expect(result.status != 0)
        #expect(result.stderr.contains("no cmux-managed hooks"), Comment(rawValue: result.stderr))
    }

    @Test(arguments: ["my/agent", "manual", "-x"])
    func idsThatCannotBeAgentsAreUnknownTargets(id: String) throws {
        let context = try makeHookContext(name: "vault-agent-bad-id")
        defer { context.cleanup() }

        let result = runAgentHook(
            context: context,
            agent: id,
            subcommand: "session-start",
            standardInput: #"{"session_id":"s"}"#
        )
        #expect(result.status != 0)
        #expect(result.stderr.contains("Unknown hooks target"), Comment(rawValue: result.stderr))
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
        private let notificationPipeline = AgentHookTestNotificationPipeline()

        func append(_ command: String) {
            lock.lock()
            commands.append(command)
            commands.append(contentsOf: notificationPipeline.effects(for: command))
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

    private func runAgentHook(
        context: HookContext,
        agent: String,
        subcommand: String,
        standardInput: String,
        extraEnvironment: [String: String] = [:]
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
            timeout: 5
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

                serveAgentHookMockClient(context: context, clientFD: clientFD)
            }
        }
    }

    private func serveAgentHookMockClient(
        context: HookContext,
        clientFD: Int32
    ) {
        defer { Darwin.close(clientFD) }
        // A hook may exit before its response arrives. A closed client must
        // not terminate the host-free test runner.
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
                context.state.append(line)
                let response = agentHookMockResponse(line: line, context: context) + "\n"
                guard writeAllToFixtureSocket(response, fd: clientFD) else { return }
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
        let result = CLIHookProcessRunner.run(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            timeout: timeout
        )
        return ProcessRunResult(
            status: result.status,
            stdout: result.stdout,
            stderr: result.stderr,
            timedOut: result.timedOut
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
