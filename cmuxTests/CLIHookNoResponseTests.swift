import Darwin
import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@_silgen_name("shm_open")
private func cmuxTestShmOpen(
    _ name: UnsafePointer<CChar>,
    _ flags: Int32,
    _ mode: mode_t
) -> Int32

@Suite("CLI hook no-response telemetry")
struct CLIHookNoResponseTests {
    final class BundleProbe {}

    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    final class MockSocketServerState: @unchecked Sendable {
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

    final class NativeAdmissionResults: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(duration: Duration, result: CodexHookProcessRunResult)] = []

        func append(duration: Duration, result: CodexHookProcessRunResult) {
            lock.lock()
            values.append((duration, result))
            lock.unlock()
        }

        func snapshot() -> [(duration: Duration, result: CodexHookProcessRunResult)] {
            lock.lock()
            let snapshot = values
            lock.unlock()
            return snapshot
        }
    }

    struct MockSocketServer {
        let handled: DispatchSemaphore

        func wait(timeout: TimeInterval) -> Bool {
            handled.wait(timeout: .now() + timeout) == .success
        }
    }

    struct FeedHookCase {
        let source: String
        let event: String
        let toolName: String
        let pidKey: String
    }

    struct OutboxRecord {
        let marker: Data
        let message: Data
    }

    @Test func nonActionableFeedHooksDoNotWaitForSocketResponseAcrossAgents() throws {
        let cases = [
            FeedHookCase(source: "codex", event: "PreToolUse", toolName: "apply_patch", pidKey: "CMUX_CODEX_PID"),
            FeedHookCase(source: "gemini", event: "PreToolUse", toolName: "read", pidKey: "CMUX_GEMINI_PID"),
            FeedHookCase(source: "kiro", event: "postToolUse", toolName: "fs_write", pidKey: "CMUX_KIRO_PID"),
            FeedHookCase(source: "hermes-agent", event: "pre_tool_call", toolName: "terminal", pidKey: "CMUX_HERMES_AGENT_PID"),
            FeedHookCase(source: "antigravity", event: "PostToolUse", toolName: "run_command", pidKey: "CMUX_ANTIGRAVITY_PID"),
        ]

        for testCase in cases {
            let cliPath = try Self.bundledCLIPath()
            let socketPath = Self.makeSocketPath("feed-no-reply-\(testCase.source.prefix(6))")
            let listenerFD = try Self.bindUnixSocket(at: socketPath, backlog: 1)
            let state = MockSocketServerState()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-feed-no-reply-\(testCase.source)-\(UUID().uuidString)", isDirectory: true)

            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
                try? FileManager.default.removeItem(at: root)
            }

            let server = Self.startMockServerAllowingNoResponse(
                listenerFD: listenerFD,
                state: state,
                fulfillWhen: { line in
                    Self.jsonObject(line)?["method"] as? String == "feed.push"
                }
            ) { line in
                guard let payload = Self.jsonObject(line),
                      payload["method"] as? String == "feed.push" else {
                    return Self.malformedRequestResponse(raw: line)
                }
                return nil
            }

            var environment = [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
                "CMUX_SURFACE_ID": "44444444-4444-4444-4444-444444444444",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
            environment[testCase.pidKey] = "626262"

            let input = """
            {"hook_event_name":"\(testCase.event)","session_id":"\(testCase.source)-session-123","cwd":"\(root.path)","tool_name":"\(testCase.toolName)","tool_input":{"path":"\(root.appendingPathComponent("README.md").path)"}}
            """
            let result = Self.runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "feed", "--source", testCase.source, "--event", testCase.event],
                environment: environment,
                standardInput: input,
                timeout: 0.5
            )

            #expect(server.wait(timeout: 5), "\(testCase.source): socket server did not observe feed.push")
            #expect(!result.timedOut, "\(testCase.source): \(result.stderr)")
            #expect(result.status == 0, "\(testCase.source): \(result.stderr)")
            #expect(result.stdout == "{}\n")
            #expect(state.snapshot().filter { $0.contains(#""method":"feed.push""#) }.count == 1)
        }
    }

    @Test func genericLifecycleFeedTelemetryDoesNotWaitForSocketResponse() throws {
        let cliPath = try Self.bundledCLIPath()
        let socketPath = Self.makeSocketPath("generic-lifecycle-no-response")
        let listenerFD = try Self.bindUnixSocket(at: socketPath, backlog: 8)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-kiro-lifecycle-no-response-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let surfaceId = "44444444-4444-4444-4444-444444444444"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let server = Self.startMultiConnectionMockServerAllowingNoResponse(
            listenerFD: listenerFD,
            state: state,
            connectionLimit: 8,
            fulfillWhen: { line in
                Self.jsonObject(line)?["method"] as? String == "feed.push"
            }
        ) { line in
            guard let payload = Self.jsonObject(line) else {
                return "OK"
            }
            guard let method = payload["method"] as? String else {
                return Self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            if method == "feed.push" {
                return nil
            }
            guard let id = payload["id"] as? String else {
                return Self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return Self.surfaceListResponse(id: id, surfaceId: surfaceId)
            case "surface.resume.set":
                return Self.v2Response(id: id, ok: true, result: ["ok": true])
            default:
                return Self.v2Response(id: id, ok: false, error: [
                    "code": "unrecognized_method",
                    "message": "unexpected method: \(method)",
                ])
            }
        }

        let result = Self.runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "kiro", "session-start"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_AGENT_LAUNCH_KIND": "kiro",
                "CMUX_AGENT_LAUNCH_EXECUTABLE": "/Users/example/.cargo/bin/kiro-cli",
                "CMUX_AGENT_LAUNCH_ARGV_B64": Self.base64NULSeparated([
                    "/Users/example/.cargo/bin/kiro-cli",
                    "chat",
                    "--agent",
                    "cmux",
                    "--resume-id",
                    "old-session",
                ]),
                "CMUX_AGENT_LAUNCH_CWD": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_SOCKET_PASSWORD": "test-password",
            ],
            standardInput: #"{"session_id":"kiro-lifecycle-no-response","cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 0.5
        )

        #expect(server.wait(timeout: 5), "socket server did not observe lifecycle feed.push")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(
            state.snapshot().contains { $0.contains(#""method":"feed.push""#) },
            "Expected lifecycle hook to still emit Feed telemetry"
        )
    }

    @Test func nonActionableFeedHookDoesNotBlockWhenAcceptedSocketStopsReading() throws {
        let cliPath = try Self.bundledCLIPath()
        let socketPath = Self.makeSocketPath("feed-no-read")
        let listenerFD = try Self.bindUnixSocket(at: socketPath, backlog: 1)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-feed-no-read-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let server = Self.startAcceptedSocketThatDoesNotRead(listenerFD: listenerFD, holdFor: 1.0)
        let largeToolInput = String(repeating: "x", count: 8 * 1024 * 1024)
        let input = """
        {"hook_event_name":"PreToolUse","session_id":"codex-session-no-read","cwd":"\(root.path)","tool_name":"apply_patch","tool_input":{"payload":"\(largeToolInput)"}}
        """

        let result = Self.runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "feed", "--source", "codex", "--event", "PreToolUse"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
                "CMUX_SURFACE_ID": "44444444-4444-4444-4444-444444444444",
                "CMUX_CODEX_PID": "626262",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: input,
            timeout: 0.5
        )

        #expect(server.wait(timeout: 5), "socket server did not accept feed.push connection")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
    }

    @Test func queuedCodexFeedTargetsRequireV2Acknowledgement() throws {
        let targets = [
            "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact",
            "PostCompact", "SubagentStart", "SubagentStop",
        ]

        for (index, event) in targets.enumerated() {
            let cliPath = try Self.bundledCLIPath()
            let socketPath = Self.makeSocketPath("feed-ack-\(index)")
            let listenerFD = try Self.bindUnixSocket(at: socketPath, backlog: 1)
            let state = MockSocketServerState()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-feed-ack-\(event)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
                try? FileManager.default.removeItem(at: root)
            }

            let server = Self.startMockServerAllowingNoResponse(
                listenerFD: listenerFD,
                state: state,
                fulfillWhen: { line in
                    Self.jsonObject(line)?["method"] as? String == "feed.push"
                }
            ) { line in
                guard let request = Self.jsonObject(line),
                      request["method"] as? String == "feed.push",
                      let id = request["id"] as? String else {
                    return Self.malformedRequestResponse(raw: line)
                }
                return Self.v2Response(id: id, ok: false, error: [
                    "code": "feed_unavailable",
                    "message": "intentional queued feed rejection",
                ])
            }

            let result = Self.runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "feed", "--source", "codex", "--event", event],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "PWD": root.path,
                    "TMPDIR": root.path,
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
                    "CMUX_SURFACE_ID": "44444444-4444-4444-4444-444444444444",
                    "CMUX_CODEX_PID": "626262",
                    "CMUX_AGENT_HOOK_DELIVERY_ID": "queued-feed-ack-\(index)",
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                ],
                standardInput: """
                {"hook_event_name":"\(event)","session_id":"queued-feed-session-\(index)","cwd":"\(root.path)","tool_name":"Read","tool_input":{"path":"README.md"}}
                """,
                timeout: 2
            )

            #expect(server.wait(timeout: 2), "\(event): socket server did not observe feed.push")
            #expect(!result.timedOut, "\(event): \(result.stderr)")
            #expect(result.status != 0, "\(event): a rejected acknowledged feed must fail the delivery CLI")
            let feedRequests = state.snapshot().compactMap(Self.jsonObject).filter {
                $0["method"] as? String == "feed.push"
            }
            #expect(feedRequests.count == 1)
            #expect(feedRequests.first?["id"] as? String != nil)
        }
    }

    @Test func queuedCodexLifecycleFeedTargetsRequireV2Acknowledgement() throws {
        let targets = [
            (subcommand: "session-start", event: "SessionStart"),
            (subcommand: "prompt-submit", event: "UserPromptSubmit"),
            (subcommand: "stop", event: "Stop"),
        ]

        for (index, target) in targets.enumerated() {
            let cliPath = try Self.bundledCLIPath()
            let socketPath = Self.makeSocketPath("life-ack-\(index)")
            let listenerFD = try Self.bindUnixSocket(at: socketPath, backlog: 4)
            let state = MockSocketServerState()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-life-ack-\(target.subcommand)-\(UUID().uuidString)", isDirectory: true)
            let workspaceID = "33333333-3333-3333-3333-333333333333"
            let surfaceID = "44444444-4444-4444-4444-444444444444"
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
                try? FileManager.default.removeItem(at: root)
            }

            let server = Self.startMultiConnectionMockServerAllowingNoResponse(
                listenerFD: listenerFD,
                state: state,
                connectionLimit: 2,
                fulfillWhen: { line in
                    Self.jsonObject(line)?["method"] as? String == "feed.push"
                }
            ) { line in
                guard let request = Self.jsonObject(line) else { return "OK" }
                guard let method = request["method"] as? String else {
                    return Self.malformedRequestResponse(id: request["id"] as? String, raw: line)
                }
                guard let id = request["id"] as? String else {
                    return Self.malformedRequestResponse(raw: line)
                }
                switch method {
                case "feed.push":
                    return Self.v2Response(id: id, ok: false, error: [
                        "code": "feed_unavailable",
                        "message": "intentional queued lifecycle feed rejection",
                    ])
                case "surface.list":
                    return Self.surfaceListResponse(id: id, surfaceId: surfaceID)
                case "agent.resolve_delivery_target":
                    return Self.v2Response(id: id, ok: false, error: [
                        "code": "not_found",
                        "message": "no process binding in fixture",
                    ])
                case "workspace.set_auto_title":
                    return Self.v2Response(id: id, ok: true, result: ["enabled": false])
                default:
                    return Self.v2Response(id: id, ok: true, result: ["ok": true])
                }
            }

            let result = Self.runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "codex", target.subcommand],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "PWD": root.path,
                    "TMPDIR": root.path,
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_WORKSPACE_ID": workspaceID,
                    "CMUX_SURFACE_ID": surfaceID,
                    "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                    "CMUX_AGENT_LAUNCH_KIND": "codex",
                    "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/codex",
                    "CMUX_AGENT_LAUNCH_CWD": root.path,
                    "CMUX_AGENT_LAUNCH_ARGV_B64": Self.base64NULSeparated(["/usr/local/bin/codex"]),
                    "CMUX_AGENT_HOOK_DELIVERY_ID": "queued-lifecycle-ack-\(index)",
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                ],
                standardInput: """
                {"hook_event_name":"\(target.event)","session_id":"queued-lifecycle-session-\(index)","turn_id":"turn-\(index)","cwd":"\(root.path)"}
                """,
                timeout: 3
            )

            #expect(server.wait(timeout: 2), "\(target.event): socket server did not observe feed.push")
            #expect(!result.timedOut, "\(target.event): \(result.stderr)")
            #expect(result.status != 0, "\(target.event): rejected feed telemetry must fail queued lifecycle delivery")
            let feedRequests = state.snapshot().compactMap(Self.jsonObject).filter {
                $0["method"] as? String == "feed.push"
            }
            #expect(feedRequests.count == 1)
            #expect(feedRequests.first?["id"] as? String != nil)
        }
    }

    @Test func rejectedQueuedFeedStaysPendingAndRetriesAfterAcknowledgement() async throws {
        let cliPath = try Self.bundledCLIPath()
        let socketPath = Self.makeSocketPath("feed-retry")
        let listenerFD = try Self.bindUnixSocket(at: socketPath, backlog: 2)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-feed-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let server = Self.startMultiConnectionMockServerAllowingNoResponse(
            listenerFD: listenerFD,
            state: state,
            connectionLimit: 2,
            fulfillWhen: { line in
                Self.jsonObject(line)?["method"] as? String == "feed.push"
            }
        ) { line in
            guard let request = Self.jsonObject(line),
                  request["method"] as? String == "feed.push",
                  let id = request["id"] as? String else {
                return Self.malformedRequestResponse(raw: line)
            }
            let attempt = state.snapshot().compactMap(Self.jsonObject).filter {
                $0["method"] as? String == "feed.push"
            }.count
            if attempt == 1 {
                return Self.v2Response(id: id, ok: false, error: [
                    "code": "feed_unavailable",
                    "message": "intentional first delivery rejection",
                ])
            }
            return Self.v2Response(id: id, ok: true, result: ["status": "acknowledged"])
        }

        let environment = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "TMPDIR": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_SURFACE_ID": "44444444-4444-4444-4444-444444444444",
            "CMUX_CODEX_PID": "626262",
        ]
        var environmentData = Data()
        for key in environment.keys.sorted() {
            environmentData.append(contentsOf: key.utf8)
            environmentData.append(0)
            environmentData.append(contentsOf: (environment[key] ?? "").utf8)
            environmentData.append(0)
        }
        let deliveryID = "queued-feed-retry"
        let payload = Data(
            #"{"hook_event_name":"PreToolUse","session_id":"queued-feed-retry-session","tool_name":"Read"}"#.utf8
        )
        let event = try #require(AgentHookDeliveryEvent(params: [
            "delivery_id": deliveryID,
            "agent": "codex",
            "subcommand": "feed:PreToolUse",
            "payload_b64": payload.base64EncodedString(),
            "environment_b64": environmentData.base64EncodedString(),
        ]))
        let queue = AgentHookDeliveryQueue(
            databaseURL: root.appendingPathComponent("deliveries.sqlite3"),
            executableURLProvider: { URL(fileURLWithPath: cliPath) },
            processTimeout: 2,
            retryBaseDelay: 60,
            retryMaximumDelay: 60
        )

        try queue.enqueue(event)
        #expect(server.wait(timeout: 2), "socket server did not observe first feed.push")
        await queue.waitUntilCurrentDrainFinishes()
        let rejected = try await queue.diagnosticStatus(for: deliveryID)
        #expect(rejected?["state"] == "pending")
        #expect(rejected?["attempts"] == "1")
        #expect(rejected?["last_error"]?.contains("status") == true)

        try await queue.retryPendingDeliveries()
        await queue.waitUntilCurrentDrainFinishes()
        let delivered = try await queue.diagnosticStatus(for: deliveryID)
        #expect(delivered?["state"] == "delivered")
        #expect(delivered?["attempts"] == "2")
        #expect(state.snapshot().compactMap(Self.jsonObject).filter {
            $0["method"] as? String == "feed.push"
        }.count == 2)
    }

    @Test func nativeCodexAdmissionPublishesAuthenticatedOutboxWithoutSocketOrWorker() throws {
        let cliPath = try Self.bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-native-admission-deadline-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let hooksDirectory = root
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux-hung-fallback", isDirectory: false)
        let fallbackArgs = root.appendingPathComponent("fallback-args.txt", isDirectory: false)
        let leaderPIDFile = root.appendingPathComponent("fallback-leader-pid.txt", isDirectory: false)
        let descendantPIDFile = root.appendingPathComponent("fallback-descendant-pid.txt", isDirectory: false)
        let outboxDirectory = root.appendingPathComponent("hook-outbox", isDirectory: true)
        let socketPath = Self.makeSocketPath("native-admission")
        let listenerFD = try Self.bindUnixSocket(at: socketPath, backlog: 8)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outboxDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outboxDirectory.path)
        let capabilityAuthority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0x51, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test.outbox"
        )
        let capability = capabilityAuthority.issueCapability()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            Self.removeOutboxSharedMemory(at: outboxDirectory)
            for pidFile in [leaderPIDFile, descendantPIDFile] {
                if let rawPID = try? String(contentsOf: pidFile, encoding: .utf8),
                   let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Darwin.kill(pid, SIGKILL)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }

        let inject = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(inject.status == 0, Comment(rawValue: inject.stderr))
        let hookPath = try #require(
            FileManager.default
                .contentsOfDirectory(at: hooksDirectory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("cmux-codex-native-hook-session-start-") }
        )
        #expect(codexHookExecutableIsMachO(hookPath.path))

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s' \"$*\" > \"$CMUX_TEST_FALLBACK_ARGS\"",
            "printf '%s' \"$$\" > \"$CMUX_TEST_LEADER_PID\"",
            "/bin/sh -c 'trap \"\" TERM; printf \"%s\" \"$$\" > \"$CMUX_TEST_DESCENDANT_PID\"; while :; do :; done' &",
            "trap 'exit 143' TERM",
            "while :; do :; done",
        ])
        let socketRequests = MockSocketServerState()
        _ = Self.startMultiConnectionMockServerAllowingNoResponse(
            listenerFD: listenerFD,
            state: socketRequests,
            connectionLimit: 1,
            fulfillWhen: { _ in true }
        ) { _ in nil }
        let payload = #"{"session_id":"deadline-session","hook_event_name":"SessionStart"}"#
        let started = ContinuousClock().now
        let result = runCodexHookProcess(
            executablePath: hookPath.path,
            arguments: [],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_SOCKET_CAPABILITY": capability,
                "CMUX_AGENT_HOOK_OUTBOX_CAPABILITY": capability,
                "CMUX_AGENT_HOOK_ENQUEUE_V1": "1",
                "CMUX_AGENT_HOOK_OUTBOX_DIR": outboxDirectory.path,
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_CODEX_PID": "4242",
                "CMUX_AGENT_HOOK_DELIVERY_ID": "native-admission-deadline",
                "CMUX_TEST_FALLBACK_ARGS": fallbackArgs.path,
                "CMUX_TEST_LEADER_PID": leaderPIDFile.path,
                "CMUX_TEST_DESCENDANT_PID": descendantPIDFile.path,
            ],
            standardInput: payload,
            timeout: 0.35
        )
        let elapsed = started.duration(to: .now)

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(elapsed < .seconds(0.15), "Hook admission took \(elapsed)")
        #expect(waitForCondition(timeout: 1) {
            Self.outboxReadyMarkers(at: outboxDirectory).count == 1
        })
        let record = try #require(Self.readOutboxRecords(at: outboxDirectory).first)
        let request = try #require(codexHookJSONObject(String(decoding: record.message, as: UTF8.self)))
        let params = try #require(request["params"] as? [String: Any])
        #expect(request["method"] as? String == "agent.hook.enqueue")
        #expect(params["delivery_id"] as? String == "native-admission-deadline")
        let encodedPayload = try #require(params["payload_b64"] as? String)
        #expect(Data(base64Encoded: encodedPayload) == Data(payload.utf8))
        let markerFields = String(decoding: record.marker, as: UTF8.self)
            .split(separator: "\n")
            .map { String($0) }
        let markerNonce = try #require(markerFields.count == 4 ? markerFields[1] : nil)
        let markerCode = try #require(Data(base64Encoded: markerFields[2]))
        #expect(!String(decoding: record.marker, as: UTF8.self).contains(capability))
        #expect(capabilityAuthority.verifiesOutboxMessage(
            nonce: markerNonce,
            code: markerCode,
            message: record.message
        ))
        Thread.sleep(forTimeInterval: 0.1)
        #expect(socketRequests.snapshot().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fallbackArgs.path))
        #expect(!FileManager.default.fileExists(atPath: leaderPIDFile.path))
        #expect(!FileManager.default.fileExists(atPath: descendantPIDFile.path))
    }

    @Test func nativeCodexAdmissionUsesBoundedEmergencyFallbackWhenForkFails() throws {
        let cliPath = try Self.bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-native-fork-failure-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let hooksDirectory = root.appendingPathComponent(".cmux/hooks", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux-emergency-fallback", isDirectory: false)
        let capturedArgs = root.appendingPathComponent("emergency-args.txt", isDirectory: false)
        let leaderPIDFile = root.appendingPathComponent("emergency-leader.pid", isDirectory: false)
        let descendantPIDFile = root.appendingPathComponent("emergency-descendant.pid", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer {
            for pidFile in [leaderPIDFile, descendantPIDFile] {
                if let rawPID = try? String(contentsOf: pidFile, encoding: .utf8),
                   let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Darwin.kill(pid, SIGKILL)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }

        let inject = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(inject.status == 0, Comment(rawValue: inject.stderr))
        let hookPath = try #require(
            FileManager.default
                .contentsOfDirectory(at: hooksDirectory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("cmux-codex-native-hook-session-start-") }
        )
        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "/bin/sleep 0.02",
            "printf '%s' \"$*\" > \"$CMUX_TEST_EMERGENCY_ARGS\"",
            "printf '%s' \"$$\" > \"$CMUX_TEST_EMERGENCY_LEADER\"",
            "/bin/sh -c 'trap \"\" TERM; printf \"%s\" \"$$\" > \"$CMUX_TEST_EMERGENCY_DESCENDANT\"; while :; do :; done' &",
            "trap 'exit 143' TERM",
            "while :; do :; done",
        ])

        let started = ContinuousClock().now
        let result = runCodexHookProcess(
            executablePath: hookPath.path,
            arguments: [],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_SOCKET_PATH": "/tmp/cmux-native-forced-fork-failure.sock",
                "CMUX_SOCKET_CAPABILITY": "test-capability",
                "CMUX_AGENT_HOOK_ENQUEUE_V1": "1",
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_CODEX_PID": "4242",
                "CMUX_AGENT_HOOK_DELIVERY_ID": "native-forced-fork-failure",
                "CMUX_TEST_FORCE_HOOK_FORK_FAILURE": "1",
                "CMUX_TEST_EMERGENCY_ARGS": capturedArgs.path,
                "CMUX_TEST_EMERGENCY_LEADER": leaderPIDFile.path,
                "CMUX_TEST_EMERGENCY_DESCENDANT": descendantPIDFile.path,
            ],
            standardInput: #"{"session_id":"fork-failure","hook_event_name":"SessionStart"}"#,
            timeout: 0.25
        )
        let elapsed = started.duration(to: .now)

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(elapsed < .seconds(0.15), "Emergency fallback took \(elapsed)")
        #expect(FileManager.default.fileExists(atPath: capturedArgs.path))
        #expect(
            try String(contentsOf: capturedArgs, encoding: .utf8)
                == "--socket /tmp/cmux-native-forced-fork-failure.sock hooks codex enqueue session-start"
        )
        for pidFile in [leaderPIDFile, descendantPIDFile] {
            let rawPID = try String(contentsOf: pidFile, encoding: .utf8)
            let pid = try #require(Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)))
            errno = 0
            #expect(Darwin.kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    @Test func nativeCodexAdmissionStaysInstantAcrossSixtyFourUnacknowledgedHooks() throws {
        let cliPath = try Self.bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-native-admission-burst-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let hooksDirectory = root.appendingPathComponent(".cmux/hooks", isDirectory: true)
        let outboxDirectory = root.appendingPathComponent("hook-outbox", isDirectory: true)
        let socketPath = Self.makeSocketPath("native-burst")
        let listenerFD = try Self.bindUnixSocket(at: socketPath, backlog: 256)
        let state = MockSocketServerState()
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outboxDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outboxDirectory.path)
        let capability = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0x62, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test.outbox-burst"
        ).issueCapability()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            Self.removeOutboxSharedMemory(at: outboxDirectory)
            try? FileManager.default.removeItem(at: root)
        }

        let inject = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(inject.status == 0, Comment(rawValue: inject.stderr))
        let hookPath = try #require(
            FileManager.default
                .contentsOfDirectory(at: hooksDirectory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("cmux-codex-native-hook-session-start-") }
        )
        _ = Self.startMultiConnectionMockServerAllowingNoResponse(
            listenerFD: listenerFD,
            state: state,
            connectionLimit: 64,
            fulfillWhen: { line in
                codexHookJSONObject(line)?["method"] as? String == "agent.hook.enqueue"
            }
        ) { line in
            codexHookJSONObject(line)?["method"] as? String == "agent.hook.enqueue" ? nil : "OK"
        }

        let results = NativeAdmissionResults()
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            let started = ContinuousClock().now
            let result = runCodexHookProcess(
                executablePath: hookPath.path,
                arguments: [],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "CMUX_SURFACE_ID": "surface-\(index)",
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_SOCKET_CAPABILITY": capability,
                    "CMUX_AGENT_HOOK_OUTBOX_CAPABILITY": capability,
                    "CMUX_AGENT_HOOK_ENQUEUE_V1": "1",
                    "CMUX_AGENT_HOOK_OUTBOX_DIR": outboxDirectory.path,
                    "CMUX_BUNDLED_CLI_PATH": "/usr/bin/false",
                    "CMUX_CODEX_PID": "\(50_000 + index)",
                    "CMUX_AGENT_HOOK_DELIVERY_ID": "native-burst-\(index)",
                ],
                standardInput: #"{"session_id":"burst-\#(index)","hook_event_name":"SessionStart"}"#,
                timeout: 0.5
            )
            results.append(duration: started.duration(to: .now), result: result)
        }

        let snapshot = results.snapshot()
        #expect(snapshot.count == 64)
        #expect(snapshot.allSatisfy { !$0.result.timedOut && $0.result.status == 0 })
        #expect(snapshot.allSatisfy { $0.result.stdout == "{}\n" })
        let maximum = try #require(snapshot.map(\.duration).max())
        #expect(maximum < .seconds(0.15), "64-way native admission max was \(maximum)")
        #expect(waitForCondition(timeout: 2) {
            Self.outboxReadyMarkers(at: outboxDirectory).count == 64
        })
        let records = try Self.readOutboxRecords(at: outboxDirectory)
        let deliveryIDs = Set(records.compactMap { record -> String? in
            guard let request = codexHookJSONObject(String(decoding: record.message, as: UTF8.self)),
                  let params = request["params"] as? [String: Any] else {
                return nil
            }
            return params["delivery_id"] as? String
        })
        #expect(deliveryIDs == Set((0..<64).map { "native-burst-\($0)" }))
        #expect(state.snapshot().isEmpty)
    }

    @Test func nativeCodexAdmissionFallsBackToLegacyCommandForOlderApp() throws {
        let cliPath = try Self.bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-native-rolling-version-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let hooksDirectory = root
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux-legacy-fallback", isDirectory: false)
        let socketPath = Self.makeSocketPath("native-rolling")
        let listenerFD = try Self.bindUnixSocket(at: socketPath, backlog: 16)
        let state = MockSocketServerState()
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let inject = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(inject.status == 0, Comment(rawValue: inject.stderr))
        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let cases: [(tag: String, expectedArguments: String)] = [
            ("session-start", "hooks codex session-start"),
            ("prompt-submit", "hooks codex prompt-submit"),
            ("stop", "hooks codex stop"),
            ("pre-tool-use", "hooks codex pre-tool-use"),
            ("post-tool-use", "hooks codex post-tool-use"),
            ("notification", "hooks codex notification"),
            ("feed-PreToolUse", "hooks feed --source codex --event PreToolUse"),
            ("feed-PermissionRequest", "hooks feed --source codex --event PermissionRequest"),
            ("feed-PostToolUse", "hooks feed --source codex --event PostToolUse"),
            ("feed-PreCompact", "hooks feed --source codex --event PreCompact"),
            ("feed-PostCompact", "hooks feed --source codex --event PostCompact"),
            ("feed-SubagentStart", "hooks feed --source codex --event SubagentStart"),
            ("feed-SubagentStop", "hooks feed --source codex --event SubagentStop"),
        ]
        let installed = try FileManager.default.contentsOfDirectory(
            at: hooksDirectory,
            includingPropertiesForKeys: nil
        )

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s' \"$*\" > \"$CMUX_TEST_FALLBACK_ARGS\"",
            "cat > \"$CMUX_TEST_FALLBACK_INPUT\"",
        ])
        _ = Self.startMultiConnectionMockServerAllowingNoResponse(
            listenerFD: listenerFD,
            state: state,
            connectionLimit: cases.count,
            fulfillWhen: { line in
                codexHookJSONObject(line)?["method"] as? String == "agent.hook.enqueue"
            }
        ) { line in
            guard let request = codexHookJSONObject(line),
                  let id = request["id"] as? String else {
                return Self.malformedRequestResponse(raw: line)
            }
            return Self.v2Response(id: id, ok: false, error: [
                "code": "unrecognized_method",
                "message": "older cmux does not support agent.hook.enqueue",
            ])
        }

        for (index, testCase) in cases.enumerated() {
            let hookPath = try #require(installed.first {
                $0.lastPathComponent.hasPrefix("cmux-codex-native-hook-\(testCase.tag)-")
            })
            #expect(codexHookExecutableIsMachO(hookPath.path))
            let fallbackArgs = root.appendingPathComponent("fallback-args-\(index).txt", isDirectory: false)
            let fallbackInput = root.appendingPathComponent("fallback-input-\(index).json", isDirectory: false)
            let payload = #"{"session_id":"rolling-version-\#(index)","hook_event_name":"\#(testCase.tag)"}"#
            let started = ContinuousClock().now
            let result = runCodexHookProcess(
                executablePath: hookPath.path,
                arguments: [],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_SOCKET_CAPABILITY": "test-capability",
                    "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                    "CMUX_CODEX_PID": "4242",
                    "CMUX_AGENT_HOOK_DELIVERY_ID": "native-rolling-version-\(index)",
                    "CMUX_TEST_FALLBACK_ARGS": fallbackArgs.path,
                    "CMUX_TEST_FALLBACK_INPUT": fallbackInput.path,
                ],
                standardInput: payload,
                timeout: 0.35
            )
            let elapsed = started.duration(to: .now)

            #expect(!result.timedOut, "\(testCase.tag): \(result.stderr)")
            #expect(result.status == 0, "\(testCase.tag): \(result.stderr)")
            #expect(result.stdout == "{}\n")
            #expect(elapsed < .seconds(0.15), "\(testCase.tag) took \(elapsed)")
            #expect(waitForCondition(timeout: 1) {
                FileManager.default.fileExists(atPath: fallbackArgs.path)
                    && FileManager.default.fileExists(atPath: fallbackInput.path)
            })
            #expect(
                try String(contentsOf: fallbackArgs, encoding: .utf8)
                    == "--socket \(socketPath) \(testCase.expectedArguments)"
            )
            #expect(try String(contentsOf: fallbackInput, encoding: .utf8) == payload)
        }
        Thread.sleep(forTimeInterval: 0.1)
        #expect(
            state.snapshot().isEmpty,
            "A helper launched by an older app must use the legacy entrypoint without probing an unsupported queue method"
        )
    }

    private static func bundledCLIPath() throws -> String {
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: BundleProbe.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = fileManager.enumerator(
            at: appBundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "cmux",
                  item.path.contains(".app/Contents/Resources/bin/cmux") else {
                continue
            }
            return item.path
        }

        throw NSError(domain: "cmux.tests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Bundled cmux CLI not found in \(appBundleURL.path)",
        ])
    }

    private static func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    private static func bindUnixSocket(at path: String, backlog: Int32) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("failed to create Unix socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "socket path too long: \(path)",
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
            throw posixError("failed to bind Unix socket")
        }
        guard Darwin.listen(fd, backlog) == 0 else {
            Darwin.close(fd)
            throw posixError("failed to listen on Unix socket")
        }
        return fd
    }

    private static func startMockServerAllowingNoResponse(
        listenerFD: Int32,
        state: MockSocketServerState,
        fulfillWhen: (@Sendable (String) -> Bool)? = nil,
        handler: @escaping @Sendable (String) -> String?
    ) -> MockSocketServer {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var didFulfill = false
            func fulfillOnce() {
                if !didFulfill {
                    didFulfill = true
                    handled.signal()
                }
            }

            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                fulfillOnce()
                return
            }
            defer { Darwin.close(clientFD) }

            readLines(from: clientFD) { line in
                state.append(line)
                if fulfillWhen?(line) == true {
                    fulfillOnce()
                }
                guard let responsePayload = handler(line) else { return }
                writeLine(responsePayload, to: clientFD)
            }
        }
        return MockSocketServer(handled: handled)
    }

    private static func startMultiConnectionMockServerAllowingNoResponse(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionLimit: Int,
        fulfillWhen: (@Sendable (String) -> Bool)? = nil,
        handler: @escaping @Sendable (String) -> String?
    ) -> MockSocketServer {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let fulfillmentLock = NSLock()
            var didFulfill = false
            func fulfillOnce() {
                fulfillmentLock.lock()
                let shouldFulfill = !didFulfill
                if shouldFulfill {
                    didFulfill = true
                }
                fulfillmentLock.unlock()
                if shouldFulfill {
                    handled.signal()
                }
            }

            var accepted = 0
            while accepted < connectionLimit {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    fulfillOnce()
                    return
                }
                accepted += 1

                DispatchQueue.global(qos: .userInitiated).async {
                    defer { Darwin.close(clientFD) }
                    readLines(from: clientFD) { line in
                        state.append(line)
                        if fulfillWhen?(line) == true {
                            fulfillOnce()
                        }
                        guard let responsePayload = handler(line) else { return }
                        writeLine(responsePayload, to: clientFD)
                    }
                }
            }
        }
        return MockSocketServer(handled: handled)
    }

    private static func startAcceptedSocketThatDoesNotRead(listenerFD: Int32, holdFor: TimeInterval) -> MockSocketServer {
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
            handled.signal()
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + holdFor)
            Darwin.close(clientFD)
        }
        return MockSocketServer(handled: handled)
    }

    private static func readLines(from fd: Int32, handle: (String) -> Void) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
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
                handle(line)
            }
        }
    }

    private static func writeLine(_ line: String, to fd: Int32) {
        let response = line + "\n"
        _ = response.withCString { ptr in
            Darwin.write(fd, ptr, strlen(ptr))
        }
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

    private static func surfaceListResponse(id: String, surfaceId: String) -> String {
        v2Response(
            id: id,
            ok: true,
            result: ["surfaces": [["id": surfaceId, "ref": "surface:1", "focused": true]]]
        )
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private static func base64NULSeparated(_ values: [String]) -> String {
        values.joined(separator: "\0").data(using: .utf8)?.base64EncodedString() ?? ""
    }

    private static func outboxReadyMarkers(at directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("ready-") }) ?? []
    }

    private static func readOutboxRecords(at directory: URL) throws -> [OutboxRecord] {
        try outboxReadyMarkers(at: directory).sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }.map { markerURL in
            let marker = try Data(contentsOf: markerURL)
            let fields = String(decoding: marker, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0) }
            guard fields.count == 4,
                  fields[0].hasPrefix("/ch"),
                  Data(base64Encoded: fields[2])?.count == 32,
                  let expectedCount = Int(fields[3]),
                  expectedCount >= 0 else {
                throw NSError(domain: "cmux.tests", code: 90, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid hook outbox marker: \(markerURL.path)",
                ])
            }
            let descriptor = fields[0].withCString { cmuxTestShmOpen($0, O_RDONLY, 0) }
            guard descriptor >= 0 else { throw posixError("open hook outbox shared memory") }
            defer { Darwin.close(descriptor) }
            guard expectedCount > 0 else {
                throw NSError(domain: "cmux.tests", code: 91, userInfo: [
                    NSLocalizedDescriptionKey: "Empty hook outbox shared memory",
                ])
            }
            let mapping = mmap(nil, expectedCount, PROT_READ, MAP_SHARED, descriptor, 0)
            guard mapping != MAP_FAILED else {
                throw posixError("map hook outbox shared memory")
            }
            let message = Data(bytes: mapping!, count: expectedCount)
            munmap(mapping, expectedCount)
            return OutboxRecord(marker: marker, message: message)
        }
    }

    private static func removeOutboxSharedMemory(at directory: URL) {
        let markers = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for markerURL in markers {
            guard let marker = try? String(contentsOf: markerURL, encoding: .utf8),
                  let name = marker.split(separator: "\n").first else {
                continue
            }
            _ = String(name).withCString { shm_unlink($0) }
        }
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String? = nil,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdinHandle: FileHandle?
        let stdinURL: URL?
        if let standardInput {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-test-stdin-\(UUID().uuidString).json")
            do {
                try Data(standardInput.utf8).write(to: url)
                let handle = try FileHandle(forReadingFrom: url)
                process.standardInput = handle
                stdinHandle = handle
                stdinURL = url
            } catch {
                try? FileManager.default.removeItem(at: url)
                return ProcessRunResult(status: -1, stdout: "", stderr: "\(error)", timedOut: false)
            }
        } else {
            stdinHandle = nil
            stdinURL = nil
        }
        defer {
            try? stdinHandle?.close()
            if let stdinURL {
                try? FileManager.default.removeItem(at: stdinURL)
            }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: "\(error)", timedOut: false)
        }

        let timedOut = finished.wait(timeout: .now() + timeout) != .success
        if timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    private static func posixError(_ message: String) -> NSError {
        NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "\(message): errno \(errno)",
        ])
    }
}
