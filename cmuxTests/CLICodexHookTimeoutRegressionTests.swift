import Dispatch
import Foundation
import Darwin
import Testing

@Suite(.serialized)
struct CLICodexHookTimeoutRegressionTests {
    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    @Test func codexHookInstallReplacesSynchronousBundledHook() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-sync-hook-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let previousCommand = "cmux_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"; if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi; if [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$CMUX_CODEX_HOOKS_DISABLED\" != \"1\" ] && [ -n \"$cmux_cli\" ]; then { if [ -n \"${CMUX_SOCKET_PATH:-}\" ]; then \"$cmux_cli\" --socket \"$CMUX_SOCKET_PATH\" hooks codex prompt-submit; else \"$cmux_cli\" hooks codex prompt-submit; fi; } || echo '{}'; else echo '{}'; fi"
        let legacyHookJSON: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    ["hooks": [["command": previousCommand, "timeout": 5, "type": "command"]]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: legacyHookJSON, options: [.prettyPrinted, .sortedKeys])
            .write(to: codexHome.appendingPathComponent("hooks.json", isDirectory: false), options: .atomic)

        let install = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(!install.timedOut, Comment(rawValue: install.stderr))
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let commands = try codexHookCommands(in: codexHome)
        let sessionStartCommands = commands.filter { $0.contains("hooks codex session-start") }
        let promptCommands = commands.filter { $0.contains("hooks codex prompt-submit") }
        let stopCommands = commands.filter { $0.contains("hooks codex stop") }
        let feedCommands = commands.filter { $0.contains("hooks feed --source codex") }
        #expect(!commands.contains(previousCommand), "Installer should remove stale synchronous hook")
        #expect(sessionStartCommands.count == 1, "Installer should install one session-start hook")
        #expect(sessionStartCommands.allSatisfy { $0.contains("nohup sh -c") && $0.contains("cat >\"$payload\"") })
        #expect(sessionStartCommands.allSatisfy { $0.contains("agent_pid=") && $0.contains("CMUX_CODEX_PID=") })
        #expect(promptCommands.count == 1, "Installer should collapse duplicate prompt hooks")
        #expect(promptCommands.allSatisfy { $0.contains("nohup sh -c") && $0.contains("cat >\"$payload\"") })
        #expect(promptCommands.allSatisfy { $0.contains("agent_pid=") && $0.contains("CMUX_CODEX_PID=") })
        #expect(stopCommands.count == 1, "Installer should install one stop hook")
        #expect(stopCommands.allSatisfy { !$0.contains("nohup sh -c") && !$0.contains(">/dev/null 2>&1 &") })
        let expectedFeedEvents: Set<String> = [
            "PreToolUse",
            "PermissionRequest",
            "PostToolUse",
            "PreCompact",
            "PostCompact",
            "SubagentStart",
            "SubagentStop",
        ]
        let installedFeedEvents = Set(feedCommands.compactMap { command in
            expectedFeedEvents.first { command.contains("--event \($0)") }
        })
        #expect(feedCommands.count == expectedFeedEvents.count, "Installer should install every Codex feed hook")
        #expect(installedFeedEvents == expectedFeedEvents)
        #expect(feedCommands.allSatisfy { !$0.contains("nohup sh -c") && !$0.contains(">/dev/null 2>&1 &") })
    }

    @Test func codexInstalledHookReturnsBeforeSlowCmuxCommandFinishes() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-async-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux", isDirectory: false)
        let capturedStdin = root.appendingPathComponent("hook-stdin.json", isDirectory: false)
        let capturedArgs = root.appendingPathComponent("hook-args.txt", isDirectory: false)
        let capturedPID = root.appendingPathComponent("hook-pid.txt", isDirectory: false)
        let doneFile = root.appendingPathComponent("hook-done.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" > \"$CMUX_TEST_ARGS\"",
            "printf '%s\\n' \"$CMUX_CODEX_PID\" > \"$CMUX_TEST_PID\"",
            "cat > \"$CMUX_TEST_STDIN\"",
            "sleep 2",
            "printf done > \"$CMUX_TEST_DONE\"",
        ])

        let install = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(!install.timedOut, Comment(rawValue: install.stderr))
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let command = try #require(codexHookCommands(in: codexHome).first { $0.contains("hooks codex prompt-submit") })
        let payload = #"{"session_id":"codex-session","prompt":"rename this workspace"}"#
        let run = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": root.path,
                "CMUX_SURFACE_ID": "surface-123",
                "CMUX_SOCKET_PATH": "/tmp/cmux-test.sock",
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_CODEX_PID": "4242",
                "CMUX_TEST_STDIN": capturedStdin.path,
                "CMUX_TEST_ARGS": capturedArgs.path,
                "CMUX_TEST_PID": capturedPID.path,
                "CMUX_TEST_DONE": doneFile.path,
            ],
            standardInput: payload,
            timeout: 1
        )

        #expect(!run.timedOut, Comment(rawValue: run.stderr))
        #expect(run.status == 0, Comment(rawValue: run.stderr))
        #expect(run.stdout == "{}\n")
        #expect(waitForFile(capturedStdin, containing: payload, timeout: 1))
        #expect(waitForFile(capturedArgs, containing: "--socket /tmp/cmux-test.sock hooks codex prompt-submit", timeout: 1))
        #expect(waitForFile(capturedPID, containing: "4242", timeout: 1))
        #expect(waitForFile(doneFile, containing: "done", timeout: 3))
    }

    @Test func codexPromptSubmitDoesNotReviveStoppedTurn() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stale-prompt-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeSocketPath("codex-stale")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let commands = CapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-stale-session"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "agentLifecycle": "idle",
                    "runtimeStatus": "idle",
                    "terminalPromptTurnIds": ["turn-done"],
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        startMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 8
        )

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-done","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"late"}"#,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let sentCommands = commands.snapshot()
        #expect(!sentCommands.contains { $0.hasPrefix("set_status codex Running ") })
        #expect(!sentCommands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(!sentCommands.contains { jsonObject($0)?["method"] as? String == "feed.push" })
        #expect(!sentCommands.contains { jsonObject($0)?["method"] as? String == "surface.resume.set" })

        let saved = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionId] as? [String: Any])
        #expect(session["agentLifecycle"] as? String == "idle")
        #expect(session["runtimeStatus"] as? String == "idle")
        #expect(session["terminalPromptTurnIds"] as? [String] == ["turn-done"])
    }

    @Test func codexSessionStartDoesNotOverwriteExistingTurnState() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stale-start-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeSocketPath("codex-start")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let commands = CapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-start-session"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "agentLifecycle": "running",
                    "runtimeStatus": "running",
                    "activePromptDepth": 1,
                    "activePromptTurnId": "turn-active",
                    "activePromptTurnIds": ["turn-active"],
                    "lastPromptTurnId": "turn-active",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        startMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 8
        )

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "session-start"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CODEX_PID": "2",
            ],
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let sentCommands = commands.snapshot()
        #expect(!sentCommands.contains { $0.hasPrefix("set_agent_lifecycle codex unknown ") })
        #expect(!sentCommands.contains { jsonObject($0)?["method"] as? String == "feed.push" })
        #expect(!sentCommands.contains { jsonObject($0)?["method"] as? String == "surface.resume.set" })

        let saved = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionId] as? [String: Any])
        #expect(session["agentLifecycle"] as? String == "running")
        #expect(session["runtimeStatus"] as? String == "running")
        #expect(session["activePromptTurnIds"] as? [String] == ["turn-active"])
    }

    @Test func codexSessionStartRefreshesCompletedPriorTurn() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-fresh-start-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeSocketPath("codex-fresh")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let commands = CapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-fresh-session"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "pid": 1,
                    "agentLifecycle": "idle",
                    "runtimeStatus": "idle",
                    "lastPromptTurnId": "turn-done",
                    "terminalPromptTurnIds": ["turn-done"],
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        startMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 8
        )

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "session-start"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let sentCommands = commands.snapshot()
        #expect(sentCommands.contains { $0.hasPrefix("set_agent_lifecycle codex unknown ") })
        #expect(sentCommands.contains { jsonObject($0)?["method"] as? String == "surface.resume.set" })

        let saved = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionId] as? [String: Any])
        #expect(session["agentLifecycle"] as? String == "unknown")
        #expect(session["runtimeStatus"] as? String == "running")
        #expect(session["lastPromptTurnId"] == nil)
        #expect(session["terminalPromptTurnIds"] as? [String] == ["turn-done"])

        let commandCountAfterSessionStart = sentCommands.count
        let latePrompt = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CODEX_PID": "1",
            ],
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-done","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"late"}"#,
            timeout: 5
        )

        #expect(!latePrompt.timedOut, Comment(rawValue: latePrompt.stderr))
        #expect(latePrompt.status == 0, Comment(rawValue: latePrompt.stderr))
        #expect(latePrompt.stdout == "{}\n")
        let commandsAfterLatePrompt = Array(commands.snapshot().dropFirst(commandCountAfterSessionStart))
        #expect(!commandsAfterLatePrompt.contains { $0.hasPrefix("set_status codex Running ") })
        #expect(!commandsAfterLatePrompt.contains { $0.hasPrefix("clear_notifications ") })
        #expect(!commandsAfterLatePrompt.contains { jsonObject($0)?["method"] as? String == "feed.push" })
        #expect(!commandsAfterLatePrompt.contains { jsonObject($0)?["method"] as? String == "surface.resume.set" })
    }

    @Test func codexSessionStartDoesNotReviveCompletedTurnFromSamePID() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-same-pid-start-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeSocketPath("codex-same")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let commands = CapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-same-pid-session"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let previousPidCapturedAt = now - 3_600
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "pid": 4242,
                    "pidCapturedAt": previousPidCapturedAt,
                    "agentLifecycle": "idle",
                    "runtimeStatus": "idle",
                    "terminalPromptTurnIds": ["turn-done"],
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        startMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 8
        )

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "session-start"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CODEX_PID": "4242",
            ],
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let sentCommands = commands.snapshot()
        #expect(!sentCommands.contains { $0.hasPrefix("set_agent_lifecycle codex unknown ") })
        #expect(!sentCommands.contains { jsonObject($0)?["method"] as? String == "surface.resume.set" })

        let saved = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionId] as? [String: Any])
        #expect(session["agentLifecycle"] as? String == "idle")
        #expect(session["runtimeStatus"] as? String == "idle")
        #expect(session["terminalPromptTurnIds"] as? [String] == ["turn-done"])
        let pidCapturedAt = try #require(session["pidCapturedAt"] as? TimeInterval)
        #expect(pidCapturedAt > previousPidCapturedAt)
    }

    /// https://github.com/manaflow-ai/cmux/issues/5676: remote/no-TTY Codex hooks can inherit another
    /// live session's `CMUX_SURFACE_ID`. With no process binding to correct that leak, the hook must
    /// decline the whole route rather than publishing the newcomer's binding, PID, or lifecycle there.
    @Test func codexHookWithoutTTYDoesNotRouteOntoDifferentLiveSurfaceOwner() throws {
        let cliPath = try bundledCLIPath()

        for ownerCase in [
            (label: "running", runtimeStatus: "running", ownerStartedAfterIncoming: false, includePidCapturedAt: true),
            (label: "needsInput", runtimeStatus: "needsInput", ownerStartedAfterIncoming: false, includePidCapturedAt: true),
            (label: "legacyRunning", runtimeStatus: "running", ownerStartedAfterIncoming: false, includePidCapturedAt: false),
            (label: "newerRunning", runtimeStatus: "running", ownerStartedAfterIncoming: true, includePidCapturedAt: true),
        ] {
            let socketPath = makeSocketPath("codex-notty")
            let listenerFD = try bindUnixSocket(at: socketPath)
            let commands = CapturedSocketCommands()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-codex-notty-\(ownerCase.label)-\(UUID().uuidString)", isDirectory: true)
            let workspaceId = "11111111-1111-1111-1111-111111111111"
            let ownerSurfaceId = "22222222-2222-2222-2222-222222222222"
            let incomingSurfaceId = "33333333-3333-3333-3333-333333333333"
            let ownerSessionId = "codex-owner-\(ownerCase.label)-session"
            let newcomerSessionId = "codex-newcomer-\(ownerCase.label)-session"

            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let ownerProcess = Process()
            ownerProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
            ownerProcess.arguments = ["30"]
            try ownerProcess.run()
            defer {
                if ownerProcess.isRunning {
                    ownerProcess.terminate()
                    ownerProcess.waitUntilExit()
                }
                Darwin.close(listenerFD)
                unlink(socketPath)
                try? FileManager.default.removeItem(at: root)
            }

            let now = Date().timeIntervalSince1970
            let ownerStartedAt = ownerCase.ownerStartedAfterIncoming ? now - 5 : now - 10
            let incomingStartedAt = now - 20
            var sessions: [String: Any] = [
                ownerSessionId: [
                    "sessionId": ownerSessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": ownerSurfaceId,
                    "cwd": root.path,
                    "pid": Int(ownerProcess.processIdentifier),
                    "pidCapturedAt": now,
                    "runtimeStatus": ownerCase.runtimeStatus,
                    "agentLifecycle": ownerCase.runtimeStatus,
                    "startedAt": ownerStartedAt,
                    "updatedAt": now,
                ],
            ]
            if !ownerCase.includePidCapturedAt,
               var ownerRecord = sessions[ownerSessionId] as? [String: Any] {
                ownerRecord.removeValue(forKey: "pidCapturedAt")
                sessions[ownerSessionId] = ownerRecord
            }
            if ownerCase.ownerStartedAfterIncoming {
                sessions[newcomerSessionId] = [
                    "sessionId": newcomerSessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": incomingSurfaceId,
                    "cwd": root.path,
                    "runtimeStatus": "idle",
                    "agentLifecycle": "idle",
                    "startedAt": incomingStartedAt,
                    "updatedAt": incomingStartedAt,
                ]
            }
            let store: [String: Any] = [
                "version": 1,
                "sessions": sessions,
            ]
            try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
                .write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
            startMockSocketServerAccepting(
                listenerFD: listenerFD,
                commands: commands,
                surfaceId: ownerSurfaceId,
                connectionLimit: 8
            )

            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = root.path
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            environment["PWD"] = root.path
            environment["CMUX_SOCKET_PATH"] = socketPath
            environment["CMUX_WORKSPACE_ID"] = workspaceId
            environment["CMUX_SURFACE_ID"] = ownerSurfaceId
            environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
            environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
            environment["CMUX_CODEX_PID"] = "\(Int(Darwin.getpid()))"
            environment["CMUX_AGENT_LAUNCH_KIND"] = "codex"
            environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/codex"
            environment["CMUX_AGENT_LAUNCH_CWD"] = root.path
            environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated(["/usr/local/bin/codex"])
            for key in ["CMUX_CLI_TTY_NAME", "CMUX_TTY_NAME", "TTY", "SSH_TTY"] {
                environment.removeValue(forKey: key)
            }

            let result = runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "codex", "prompt-submit"],
                environment: environment,
                standardInput: #"{"session_id":"\#(newcomerSessionId)","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
                timeout: 5
            )

            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")

            let sentCommands = commands.snapshot()
            #expect(
                !sentCommands.contains { jsonObject($0)?["method"] as? String == "surface.resume.set" },
                "no-TTY hook for \(ownerCase.label) owner must not publish newcomer resume binding: \(sentCommands)"
            )
            #expect(
                !sentCommands.contains { $0.hasPrefix("set_agent_pid codex.\(newcomerSessionId) ") },
                "no-TTY hook for \(ownerCase.label) owner must not route newcomer PID: \(sentCommands)"
            )
            #expect(
                !sentCommands.contains { $0.hasPrefix("set_agent_lifecycle codex running ") },
                "no-TTY hook for \(ownerCase.label) owner must not route newcomer lifecycle: \(sentCommands)"
            )

            let storeURL = root.appendingPathComponent("codex-hook-sessions.json")
            let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
            let savedSessions = try #require(saved["sessions"] as? [String: Any])
            #expect(savedSessions[ownerSessionId] as? [String: Any] != nil)
            if ownerCase.ownerStartedAfterIncoming {
                let incomingRecord = try #require(savedSessions[newcomerSessionId] as? [String: Any])
                #expect(incomingRecord["surfaceId"] as? String == incomingSurfaceId)
            } else {
                #expect(savedSessions[newcomerSessionId] as? [String: Any] == nil)
            }
        }
    }

    @Test func codexHookWithoutTTYCanRouteWhenSurfaceOwnerIsStoppedOrRecycled() throws {
        let cliPath = try bundledCLIPath()

        for ownerCase in [("idle", false), ("running", true)] {
            let socketPath = makeSocketPath("codex-take")
            let listenerFD = try bindUnixSocket(at: socketPath)
            let commands = CapturedSocketCommands()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-codex-take-\(ownerCase.0)-\(UUID().uuidString)", isDirectory: true)
            let workspaceId = "11111111-1111-1111-1111-111111111111"
            let surfaceId = "22222222-2222-2222-2222-222222222222"
            let ownerSessionId = "codex-takeover-owner-\(ownerCase.0)-session"
            let newcomerSessionId = "codex-takeover-new-\(ownerCase.0)-session"

            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let ownerProcess = Process()
            ownerProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
            ownerProcess.arguments = ["30"]
            try ownerProcess.run()
            defer {
                if ownerProcess.isRunning {
                    ownerProcess.terminate()
                    ownerProcess.waitUntilExit()
                }
                Darwin.close(listenerFD)
                unlink(socketPath)
                try? FileManager.default.removeItem(at: root)
            }

            let now = Date().timeIntervalSince1970
            let ownerUpdatedAt = ownerCase.1 ? now - 60 : now
            let store: [String: Any] = [
                "version": 1,
                "sessions": [
                    ownerSessionId: [
                        "sessionId": ownerSessionId,
                        "workspaceId": workspaceId,
                        "surfaceId": surfaceId,
                        "cwd": root.path,
                        "pid": Int(ownerProcess.processIdentifier),
                        "pidCapturedAt": ownerUpdatedAt,
                        "runtimeStatus": ownerCase.0,
                        "agentLifecycle": ownerCase.0,
                        "startedAt": ownerUpdatedAt - 10,
                        "updatedAt": ownerUpdatedAt,
                    ],
                ],
            ]
            try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
                .write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
            startMockSocketServerAccepting(
                listenerFD: listenerFD,
                commands: commands,
                surfaceId: surfaceId,
                connectionLimit: 8
            )

            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = root.path
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            environment["PWD"] = root.path
            environment["CMUX_SOCKET_PATH"] = socketPath
            environment["CMUX_WORKSPACE_ID"] = workspaceId
            environment["CMUX_SURFACE_ID"] = surfaceId
            environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
            environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
            environment["CMUX_CODEX_PID"] = "\(Int(Darwin.getpid()))"
            environment["CMUX_AGENT_LAUNCH_KIND"] = "codex"
            environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/codex"
            environment["CMUX_AGENT_LAUNCH_CWD"] = root.path
            environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated(["/usr/local/bin/codex"])
            for key in ["CMUX_CLI_TTY_NAME", "CMUX_TTY_NAME", "TTY", "SSH_TTY"] {
                environment.removeValue(forKey: key)
            }

            let result = runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "codex", "prompt-submit"],
                environment: environment,
                standardInput: #"{"session_id":"\#(newcomerSessionId)","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
                timeout: 5
            )

            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))

            let resumeRequests = commands.snapshot().compactMap { command -> [String: Any]? in
                guard let payload = jsonObject(command),
                      payload["method"] as? String == "surface.resume.set" else { return nil }
                return payload["params"] as? [String: Any]
            }
            let params = try #require(
                resumeRequests.last,
                "stopped or recycled owner should not block no-TTY takeover; saw \(commands.snapshot())"
            )
            #expect(params["surface_id"] as? String == surfaceId)
            #expect(params["checkpoint_id"] as? String == newcomerSessionId)
            #expect(
                commands.snapshot().contains { $0.hasPrefix("set_agent_pid codex.\(newcomerSessionId) ") },
                "takeover should route newcomer PID after stopped/recycled owner: \(commands.snapshot())"
            )
        }
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
    }

    private func codexHookTestEnvironment(root: URL, codexHome: URL) -> [String: String] {
        [
            "HOME": root.path,
            "CODEX_HOME": codexHome.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
    }

    private func codexHookCommands(in codexHome: URL) throws -> [String] {
        let hookURL = codexHome.appendingPathComponent("hooks.json", isDirectory: false)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: hookURL)) as? [String: Any])
        let hooks = try #require(json["hooks"] as? [String: Any])
        return hooks.values
            .compactMap { $0 as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }
    }

    private func makeExecutableShellFile(at url: URL, lines: [String]) throws {
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private final class CapturedSocketCommands: @unchecked Sendable {
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

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "cmux.tests", code: Int(errno))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG))
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
        guard bindResult == 0, Darwin.listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(code))
        }
        return fd
    }

    private func startMockSocketServerAccepting(
        listenerFD: Int32,
        commands: CapturedSocketCommands,
        surfaceId: String,
        connectionLimit: Int
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
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
                    return
                }
                accepted += 1
                DispatchQueue.global(qos: .userInitiated).async {
                    handleMockSocketClient(fd: clientFD, commands: commands, surfaceId: surfaceId)
                }
            }
        }
    }

    private func handleMockSocketClient(
        fd clientFD: Int32,
        commands: CapturedSocketCommands,
        surfaceId: String
    ) {
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
                commands.append(line)
                let response = mockSocketResponse(for: line, surfaceId: surfaceId) + "\n"
                _ = response.withCString { ptr in
                    Darwin.write(clientFD, ptr, strlen(ptr))
                }
            }
        }
    }

    private func mockSocketResponse(for line: String, surfaceId: String) -> String {
        guard let payload = jsonObject(line),
              let id = payload["id"] as? String else {
            return "OK"
        }
        switch payload["method"] as? String {
        case "surface.list":
            return v2Response(
                id: id,
                ok: true,
                result: ["surfaces": [["id": surfaceId, "ref": surfaceId, "focused": true]]]
            )
        case "debug.terminals":
            return v2Response(id: id, ok: true, result: ["terminals": []])
        case "system.top":
            return v2Response(id: id, ok: true, result: ["windows": []])
        default:
            return v2Response(id: id, ok: true, result: [:])
        }
    }

    private func base64NULSeparated(_ values: [String]) -> String {
        values.joined(separator: "\0").data(using: .utf8)?.base64EncodedString() ?? ""
    }

    private func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    private func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String? = nil,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = standardInput == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }
        if let standardInput, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            try? stdinPipe.fileHandleForWriting.close()
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

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    private func waitForFile(_ url: URL, containing expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let content = try? String(contentsOf: url, encoding: .utf8), content.contains(expected) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }
}
