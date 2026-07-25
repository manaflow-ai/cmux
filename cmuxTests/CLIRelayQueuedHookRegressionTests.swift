import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CLIRelayQueuedHookRegressionTests {
    private let remoteWorkspaceID = "11111111-1111-1111-1111-111111111111"
    private let remoteSurfaceID = "22222222-2222-2222-2222-222222222222"
    private let replayWorkspaceID = "33333333-3333-3333-3333-333333333333"
    private let replaySurfaceID = "44444444-4444-4444-4444-444444444444"

    @Test("Relay admission resolves a Grok hook's remote TTY before replay")
    func relayAdmissionPreservesGrokRoutingIdentity() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let relay = try RelayQueuedHookMockServer(
            ttyName: "8535",
            workspaceID: remoteWorkspaceID,
            surfaceID: remoteSurfaceID
        )
        relay.start()
        defer { relay.close() }

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", relay.endpoint,
                "hooks", "enqueue", "grok", "stop",
            ],
            environment: relayEnvironment(
                home: FileManager.default.temporaryDirectory,
                extra: ["SSH_TTY": "/dev/pts/8535"]
            ),
            standardInput: #"{"session_id":"grok-relay-session","hook_event_name":"Stop"}"#,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let params = try admittedParams(from: relay)
        let environment = try #require(params["environment"] as? [String: Any])
        #expect(environment["CMUX_WORKSPACE_ID"] as? String == remoteWorkspaceID)
        #expect(environment["CMUX_SURFACE_ID"] as? String == remoteSurfaceID)
        #expect(relay.requests().contains {
            $0["method"] as? String == "debug.terminals"
        })
    }

    @Test("Relay admission carries transcript-only Codex failures into local replay")
    func relayAdmissionPreservesCodexFailureEvidence() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-relay-codex-evidence-\(UUID().uuidString)",
            isDirectory: true
        )
        let transcript = root.appendingPathComponent("rollout.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"remote-turn"}}
        {"type":"event_msg","payload":{"type":"stream_error","turn_id":"remote-turn","message":"Remote response stream disconnected","codex_error_info":"response_stream_disconnected","additional_details":"connection reset"}}
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"remote-turn","last_agent_message":null}}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let relay = try RelayQueuedHookMockServer(
            ttyName: "8536",
            workspaceID: remoteWorkspaceID,
            surfaceID: remoteSurfaceID
        )
        relay.start()
        defer { relay.close() }
        let admission = runCodexHookProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", relay.endpoint,
                "hooks", "enqueue", "codex", "stop",
            ],
            environment: relayEnvironment(
                home: root,
                extra: [
                    "SSH_TTY": "/dev/pts/8536",
                    "CMUX_WORKSPACE_ID": "stale-workspace",
                    "CMUX_SURFACE_ID": "stale-surface",
                ]
            ),
            standardInput: """
            {"session_id":"codex-relay-session","turn_id":"remote-turn","transcript_path":"\(transcript.path)","hook_event_name":"Stop","last_assistant_message":null}
            """,
            timeout: 5
        )

        #expect(!admission.timedOut, Comment(rawValue: admission.stderr))
        #expect(admission.status == 0, Comment(rawValue: admission.stderr))
        let params = try admittedParams(from: relay)
        let payload = try #require(params["payload"] as? String)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        )
        #expect(object["type"] as? String == "stream_error")
        #expect(object["message"] as? String == "Remote response stream disconnected")
        #expect(object["codex_error_info"] as? String == "response_stream_disconnected")

        let commands = try replay(
            cliPath: cliPath,
            root: root,
            agent: "codex",
            subcommand: "stop",
            payload: payload
        )
        #expect(commands.contains {
            $0.hasPrefix("set_status codex ")
                && $0.contains("--icon=exclamationmark.triangle.fill")
                && $0.contains("--color=#FF453A")
        }, Comment(rawValue: commands.joined(separator: "\n")))
    }

    @Test("Relay admission resolves the Rovo session on the remote filesystem")
    func relayAdmissionPreservesRovoSessionIdentity() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-relay-rovo-session-\(UUID().uuidString)",
            isDirectory: true
        )
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let sessionID = "rovo-relay-session"
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try writeRovoSession(
            sessionsRoot: sessionsRoot,
            sessionID: sessionID,
            workspace: workspace
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let relay = try RelayQueuedHookMockServer(
            ttyName: "8537",
            workspaceID: remoteWorkspaceID,
            surfaceID: remoteSurfaceID
        )
        relay.start()
        defer { relay.close() }
        let admission = runCodexHookProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", relay.endpoint,
                "hooks", "enqueue", "rovodev", "stop",
            ],
            environment: relayEnvironment(
                home: root,
                extra: [
                    "SSH_TTY": "/dev/pts/8537",
                    "PWD": workspace.path,
                    "CMUX_ROVODEV_SESSIONS_DIR": sessionsRoot.path,
                    "CMUX_WORKSPACE_ID": "stale-workspace",
                    "CMUX_SURFACE_ID": "stale-surface",
                ]
            ),
            standardInput: """
            {"cwd":"\(workspace.path)","hook_event_name":"on_complete","message":"Remote Rovo completed"}
            """,
            timeout: 5
        )

        #expect(!admission.timedOut, Comment(rawValue: admission.stderr))
        #expect(admission.status == 0, Comment(rawValue: admission.stderr))
        let params = try admittedParams(from: relay)
        let payload = try #require(params["payload"] as? String)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        )
        #expect(object["session_id"] as? String == sessionID)

        _ = try replay(
            cliPath: cliPath,
            root: root,
            agent: "rovodev",
            subcommand: "stop",
            payload: payload
        )
        let storeURL = root.appendingPathComponent(
            "rovodev-hook-sessions.json",
            isDirectory: false
        )
        let store = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any]
        )
        let sessions = try #require(store["sessions"] as? [String: Any])
        #expect(sessions[sessionID] != nil)
    }

    @Test("Relay replay strips remote filesystem identity and omits a synthetic local agent PID")
    func relayReplayUsesOnlyPortableFeedIdentity() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-relay-portable-feed-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let relay = try RelayQueuedHookMockServer(
            ttyName: "8539",
            workspaceID: remoteWorkspaceID,
            surfaceID: remoteSurfaceID
        )
        relay.start()
        defer { relay.close() }
        let admission = runCodexHookProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", relay.endpoint,
                "hooks", "enqueue", "gemini", "prompt-submit",
            ],
            environment: relayEnvironment(
                home: root,
                extra: [
                    "SSH_TTY": "/dev/pts/8539",
                    "CMUX_GEMINI_PID": "8539",
                    "CMUX_WORKSPACE_ID": "stale-workspace",
                    "CMUX_SURFACE_ID": "stale-surface",
                ]
            ),
            standardInput: """
            {
              "session_id":"gemini-relay-session",
              "hook_event_name":"BeforeAgent",
              "prompt":"portable relay prompt",
              "cwd":"/remote/repo",
              "transcript_path":"/remote/transcripts/session.jsonl",
              "workspacePaths":["/remote/workspace"],
              "data":{"workingDirectory":"/remote/data","transcriptPath":"/remote/data/session.jsonl"},
              "context":{"projectDir":"/remote/context"}
            }
            """,
            timeout: 5
        )

        #expect(!admission.timedOut, Comment(rawValue: admission.stderr))
        #expect(admission.status == 0, Comment(rawValue: admission.stderr))
        let params = try admittedParams(from: relay)
        let payload = try #require(params["payload"] as? String)
        let portableObject = try #require(
            JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        )
        #expect(!containsRemoteFilesystemLocation(in: portableObject))
        #expect(portableObject["session_id"] as? String == "gemini-relay-session")
        #expect(portableObject["prompt"] as? String == "portable relay prompt")

        let commands = try replay(
            cliPath: cliPath,
            root: root,
            agent: "gemini",
            subcommand: "prompt-submit",
            payload: payload,
            waitingForMethod: "feed.push"
        )
        let feedPush = try #require(commands.compactMap(codexHookJSONObject).first {
            $0["method"] as? String == "feed.push"
        })
        let feedParams = try #require(feedPush["params"] as? [String: Any])
        let event = try #require(feedParams["event"] as? [String: Any])
        #expect(event["cwd"] == nil)
        #expect(event["transcript_path"] == nil)
        #expect(event["_ppid"] == nil)
    }

    @Test("Relay replay preserves a Claude fork's parent through start and early end")
    func relayReplayPreservesClaudeForkParentRecord() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-relay-claude-fork-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let parentSessionID = "claude-parent-session"
        let parentSurfaceID = "55555555-5555-5555-5555-555555555555"
        let relay = try RelayQueuedHookMockServer(
            ttyName: "8538",
            workspaceID: remoteWorkspaceID,
            surfaceID: remoteSurfaceID
        )
        relay.start()
        defer { relay.close() }
        let launchArguments = [
            "/remote/bin/claude", "--resume", parentSessionID, "--fork-session",
        ]
        let launchArgumentsBase64 = Data(
            launchArguments.joined(separator: "\0").utf8
        ).base64EncodedString()
        let environment = relayEnvironment(
            home: root,
            extra: [
                "SSH_TTY": "/dev/pts/8538",
                "CMUX_AGENT_LAUNCH_KIND": "claude",
                "CMUX_AGENT_LAUNCH_ARGV_B64": launchArgumentsBase64,
                "CMUX_WORKSPACE_ID": "stale-workspace",
                "CMUX_SURFACE_ID": "stale-surface",
            ]
        )

        let sessionStartPayload = """
        {"session_id":"\(parentSessionID)","source":"resume","cwd":"/remote/repo","hook_event_name":"SessionStart"}
        """
        let sessionStartAdmission = runCodexHookProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", relay.endpoint,
                "hooks", "enqueue", "claude", "session-start",
            ],
            environment: environment,
            standardInput: sessionStartPayload,
            timeout: 5
        )
        #expect(!sessionStartAdmission.timedOut, Comment(rawValue: sessionStartAdmission.stderr))
        #expect(sessionStartAdmission.status == 0, Comment(rawValue: sessionStartAdmission.stderr))
        let admittedSessionStart = try admittedParams(
            from: relay,
            subcommand: "session-start"
        )
        let portableSessionStartPayload = try #require(
            admittedSessionStart["payload"] as? String
        )
        let portableSessionStart = try #require(
            JSONSerialization.jsonObject(
                with: Data(portableSessionStartPayload.utf8)
            ) as? [String: Any]
        )
        #expect(portableSessionStart["_cmux_claude_fork_session"] as? Bool == true)
        #expect(
            portableSessionStart["_cmux_claude_fork_parent_session_id"] as? String
                == parentSessionID
        )

        try seedClaudeParentStore(
            root: root,
            sessionID: parentSessionID,
            parentSurfaceID: parentSurfaceID
        )
        _ = try replay(
            cliPath: cliPath,
            root: root,
            agent: "claude",
            subcommand: "session-start",
            payload: portableSessionStartPayload
        )
        var parentRecord = try claudeSessionRecord(
            root: root,
            sessionID: parentSessionID
        )
        #expect(parentRecord["surfaceId"] as? String == parentSurfaceID)

        let sessionEndPayload = """
        {"session_id":"\(parentSessionID)","cwd":"/remote/repo","hook_event_name":"SessionEnd"}
        """
        let sessionEndAdmission = runCodexHookProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", relay.endpoint,
                "hooks", "enqueue", "claude", "session-end",
            ],
            environment: environment,
            standardInput: sessionEndPayload,
            timeout: 5
        )
        #expect(!sessionEndAdmission.timedOut, Comment(rawValue: sessionEndAdmission.stderr))
        #expect(sessionEndAdmission.status == 0, Comment(rawValue: sessionEndAdmission.stderr))
        let admittedSessionEnd = try admittedParams(
            from: relay,
            subcommand: "session-end"
        )
        let portableSessionEndPayload = try #require(
            admittedSessionEnd["payload"] as? String
        )

        try seedClaudeParentStore(
            root: root,
            sessionID: parentSessionID,
            parentSurfaceID: parentSurfaceID
        )
        _ = try replay(
            cliPath: cliPath,
            root: root,
            agent: "claude",
            subcommand: "session-end",
            payload: portableSessionEndPayload
        )
        parentRecord = try claudeSessionRecord(
            root: root,
            sessionID: parentSessionID
        )
        #expect(parentRecord["surfaceId"] as? String == parentSurfaceID)
    }

    private func replay(
        cliPath: String,
        root: URL,
        agent: String,
        subcommand: String,
        payload: String,
        waitingForMethod: String? = nil
    ) throws -> [String] {
        let socketPath = makeCodexHookSocketPath("relay-replay")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let captured = CodexHookCapturedSocketCommands()
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: captured,
            surfaceId: replaySurfaceID,
            connectionLimit: 32
        )
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", agent, subcommand],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": replayWorkspaceID,
                "CMUX_SURFACE_ID": replaySurfaceID,
                "CMUX_AGENT_HOOK_RELAY_ORIGIN": "1",
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: payload,
            timeout: 10
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        if let waitingForMethod {
            #expect(waitForCondition(timeout: 2) {
                captured.snapshot().compactMap(codexHookJSONObject).contains {
                    $0["method"] as? String == waitingForMethod
                }
            })
        }
        return captured.snapshot()
    }

    private func containsRemoteFilesystemLocation(in value: Any) -> Bool {
        let locationKeys: Set<String> = [
            "cwd",
            "working_directory",
            "workingDirectory",
            "project_dir",
            "projectDir",
            "project_path",
            "projectPath",
            "workspacePaths",
            "workspace_paths",
            "transcript_path",
            "transcriptPath",
        ]
        if let object = value as? [String: Any] {
            return object.contains { key, nestedValue in
                locationKeys.contains(key)
                    || containsRemoteFilesystemLocation(in: nestedValue)
            }
        }
        if let array = value as? [Any] {
            return array.contains { containsRemoteFilesystemLocation(in: $0) }
        }
        return false
    }

    private func relayEnvironment(
        home: URL,
        extra: [String: String]
    ) -> [String: String] {
        var environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_RELAY_ID": RelayQueuedHookMockServer.relayID,
            "CMUX_RELAY_TOKEN": String(repeating: "a", count: 64),
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        environment.merge(extra, uniquingKeysWith: { _, value in value })
        return environment
    }

    private func admittedParams(
        from relay: RelayQueuedHookMockServer,
        subcommand: String? = nil
    ) throws -> [String: Any] {
        let requests = relay.requests()
        let request = try #require(requests.first {
            guard $0["method"] as? String == "agent.hook.enqueue" else {
                return false
            }
            guard let subcommand else { return true }
            return ($0["params"] as? [String: Any])?["subcommand"] as? String
                == subcommand
        }, Comment(rawValue: String(describing: requests)))
        return try #require(request["params"] as? [String: Any])
    }

    private func seedClaudeParentStore(
        root: URL,
        sessionID: String,
        parentSurfaceID: String
    ) throws {
        let now = Date().timeIntervalSince1970
        let active: [String: Any] = [
            "sessionId": sessionID,
            "updatedAt": now,
        ]
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionID: [
                    "sessionId": sessionID,
                    "workspaceId": replayWorkspaceID,
                    "surfaceId": parentSurfaceID,
                    "cwd": root.path,
                    "agentLifecycle": "running",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
            "activeSessionsByWorkspace": [
                replayWorkspaceID: active,
            ],
            "activeSessionsBySurface": [
                parentSurfaceID: active,
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: store,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: root.appendingPathComponent("claude-hook-sessions.json"),
            options: .atomic
        )
    }

    private func claudeSessionRecord(
        root: URL,
        sessionID: String
    ) throws -> [String: Any] {
        let data = try Data(
            contentsOf: root.appendingPathComponent("claude-hook-sessions.json")
        )
        let store = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let sessions = try #require(store["sessions"] as? [String: Any])
        return try #require(sessions[sessionID] as? [String: Any])
    }

    private func writeRovoSession(
        sessionsRoot: URL,
        sessionID: String,
        workspace: URL
    ) throws {
        let session = sessionsRoot.appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let metadata = try JSONSerialization.data(withJSONObject: [
            "title": "Remote Rovo",
            "workspace_path": workspace.path,
        ])
        try metadata.write(to: session.appendingPathComponent("metadata.json"), options: .atomic)
        try Data(#"{"message_history":[]}"#.utf8).write(
            to: session.appendingPathComponent("session_context.json"),
            options: .atomic
        )
    }
}

private final class RelayQueuedHookMockServer: @unchecked Sendable {
    static let relayID = "relay-hook-regression"

    private let listenerFD: Int32
    private let port: UInt16
    private let ttyName: String
    private let workspaceID: String
    private let surfaceID: String
    private let captured = CodexHookCapturedSocketCommands()
    private let acceptGroup = DispatchGroup()

    var endpoint: String { "127.0.0.1:\(port)" }

    init(ttyName: String, workspaceID: String, surfaceID: String) throws {
        self.ttyName = ttyName
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var reuse: Int32 = 1
        _ = Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var local = sockaddr_in()
        var localLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &local, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &localLength)
            }
        }) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        listenerFD = fd
        port = UInt16(bigEndian: local.sin_port)
    }

    func start() {
        acceptGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { acceptGroup.leave() }
            while true {
                let clientFD = Darwin.accept(listenerFD, nil, nil)
                guard clientFD >= 0 else { return }
                handle(clientFD: clientFD)
            }
        }
    }

    func requests() -> [[String: Any]] {
        captured.snapshot().compactMap(codexHookJSONObject)
    }

    func close() {
        Darwin.shutdown(listenerFD, SHUT_RDWR)
        Darwin.close(listenerFD)
        acceptGroup.wait()
    }

    private func handle(clientFD: Int32) {
        defer { Darwin.close(clientFD) }
        writeLine(
            #"{"protocol":"cmux-relay-auth","version":1,"relay_id":"\#(Self.relayID)","nonce":"relay-nonce"}"#,
            to: clientFD
        )
        guard readLine(from: clientFD) != nil else { return }
        writeLine(#"{"ok":true}"#, to: clientFD)

        while let line = readLine(from: clientFD) {
            captured.append(line)
            guard let request = codexHookJSONObject(line),
                  let id = request["id"] as? String else {
                writeLine("OK", to: clientFD)
                continue
            }
            let method = request["method"] as? String
            let result: [String: Any]
            switch method {
            case "debug.terminals":
                result = ["terminals": [[
                    "tty": ttyName,
                    "workspace_id": workspaceID,
                    "surface_id": surfaceID,
                ]]]
            case "surface.list":
                result = ["surfaces": [[
                    "id": surfaceID,
                    "ref": surfaceID,
                    "focused": true,
                ]]]
            default:
                result = [:]
            }
            writeLine(
                codexHookV2Response(id: id, ok: true, result: result),
                to: clientFD
            )
        }
    }

    private func readLine(from fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 { return bytes.isEmpty ? nil : String(bytes: bytes, encoding: .utf8) }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if byte == 0x0A { return String(bytes: bytes, encoding: .utf8) }
            bytes.append(byte)
        }
    }

    private func writeLine(_ line: String, to fd: Int32) {
        let data = Data((line + "\n").utf8)
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}
