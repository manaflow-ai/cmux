import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CLICodexHookTimeoutRegressionTests {
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

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 10
        )
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let hooks = try codexHookEntries(in: codexHome)
        let sessionStartHooks = hooks.filter { $0.eventName == "SessionStart" }
        let promptHooks = hooks.filter { $0.eventName == "UserPromptSubmit" }
        let stopHooks = hooks.filter { $0.eventName == "Stop" }
        #expect(!hooks.map(\.body).contains(previousCommand), "Installer should remove stale synchronous hook")
        #expect(sessionStartHooks.count == 1, "Installer should install one session-start hook")
        #expect(sessionStartHooks.allSatisfy { $0.body.contains("hooks codex session-start") })
        #expect(sessionStartHooks.allSatisfy { $0.body.contains("nohup sh -c") && $0.body.contains("cat >\"$payload\"") })
        #expect(sessionStartHooks.allSatisfy { $0.body.contains("agent_pid=") && $0.body.contains("CMUX_CODEX_PID=") })
        #expect(promptHooks.count == 1, "Installer should collapse duplicate prompt hooks")
        #expect(promptHooks.allSatisfy { $0.body.contains("hooks codex prompt-submit") })
        #expect(promptHooks.allSatisfy { $0.body.contains("nohup sh -c") && $0.body.contains("cat >\"$payload\"") })
        #expect(promptHooks.allSatisfy { $0.body.contains("agent_pid=") && $0.body.contains("CMUX_CODEX_PID=") })
        #expect(stopHooks.count == 1, "Installer should install one stop hook")
        #expect(stopHooks.allSatisfy { $0.body.contains("hooks codex stop") })
        #expect(stopHooks.allSatisfy { $0.body.contains("nohup sh -c") && $0.body.contains("cat >\"$payload\"") })
        #expect(stopHooks.allSatisfy { $0.body.contains("agent_pid=") && $0.body.contains("CMUX_CODEX_PID=") })
        let wrapperEquivalentEvents = [
            "PreToolUse": "pre-tool-use",
            "PermissionRequest": "notification",
            "PostToolUse": "post-tool-use",
        ]
        for (eventName, subcommand) in wrapperEquivalentEvents {
            let eventHooks = hooks.filter { $0.eventName == eventName }
            #expect(eventHooks.count == 1, "Installer should install one \(eventName) hook")
            #expect(eventHooks.allSatisfy { $0.body.contains("hooks codex \(subcommand)") })
            #expect(eventHooks.allSatisfy {
                $0.body.contains("nohup sh -c") && $0.body.contains("cat >\"$payload\"")
            })
        }

        let persistentOnlyFeedEvents: Set<String> = [
            "PreCompact",
            "PostCompact",
            "SubagentStart",
            "SubagentStop",
        ]
        let persistentOnlyFeedHooks = hooks.filter { hook in
            hook.body.contains("hooks feed --source codex")
                && persistentOnlyFeedEvents.contains(hook.eventName)
        }
        let installedFeedEvents = Set(persistentOnlyFeedHooks.compactMap { hook in
            persistentOnlyFeedEvents.first { hook.body.contains("--event \($0)") }
        })
        #expect(persistentOnlyFeedHooks.count == persistentOnlyFeedEvents.count)
        #expect(installedFeedEvents == persistentOnlyFeedEvents)
        #expect(persistentOnlyFeedHooks.allSatisfy {
            !$0.body.contains("nohup sh -c") && !$0.body.contains(">/dev/null 2>&1 &")
        })
    }

    @Test func codexWrapperPreservesPersistentSettingsAndInjectsOnlyMissingEvents() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-settings-preserved-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = codexHookTestEnvironment(root: root, codexHome: codexHome)
        let hooksURL = codexHome.appendingPathComponent("hooks.json", isDirectory: false)
        let configURL = codexHome.appendingPathComponent("config.toml", isDirectory: false)
        let hooksContent = #"""
        {"custom":{"format":"must stay exact"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"cmux hooks codex stop","timeout":5},{"type":"command","command":"/usr/local/bin/user-stop","timeout":42}]}]}}
        """#
        let configContent = """
        model = "gpt-5.5"
        approval_policy = "on-request"

        [features]
        hooks = false

        [custom]
        keep = "exactly"
        """
        try Data(hooksContent.utf8).write(to: hooksURL, options: .atomic)
        try Data(configContent.utf8).write(to: configURL, options: .atomic)
        let hooksBeforeLaunch = try Data(contentsOf: hooksURL)
        let configBeforeLaunch = try Data(contentsOf: configURL)

        let emit = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: environment,
            timeout: 10
        )
        #expect(!emit.timedOut, Comment(rawValue: emit.stderr))
        #expect(emit.status == 0, Comment(rawValue: emit.stderr))

        let emittedEvents = injectedCodexHookEventNames(emit.stdout)
        let emittedArguments = emit.stdout.split(separator: "\0").map(String.init)
        #expect(Array(emittedArguments.prefix(3)) == [
            "--enable",
            "hooks",
            "--dangerously-bypass-hook-trust",
        ])
        let expectedInjectedEvents: Set<String> = [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PermissionRequest",
            "SubagentStart",
            "SubagentStop",
        ]
        #expect(Set(emittedEvents) == expectedInjectedEvents)
        #expect(emittedEvents.count == expectedInjectedEvents.count)

        let hooksAfterLaunch = try Data(contentsOf: hooksURL)
        let configAfterLaunch = try Data(contentsOf: configURL)
        #expect(hooksAfterLaunch == hooksBeforeLaunch)
        #expect(configAfterLaunch == configBeforeLaunch)
    }

    @Test func codexPermissionRequestHandlerPreservesFeedTelemetryAndNeedsInputState() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-permission-handler-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-permission")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 16
        )

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "notification"],
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
            standardInput: #"{"session_id":"codex-permission-session","cwd":"\#(root.path)","hook_event_name":"PermissionRequest","message":"approval required"}"#,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(waitForConditionBlocking(timeout: 1) {
            commands.snapshot().contains { command in
                guard let object = codexHookJSONObject(command),
                      object["method"] as? String == "feed.push",
                      let params = object["params"] as? [String: Any],
                      let event = params["event"] as? [String: Any] else {
                    return false
                }
                return event["hook_event_name"] as? String == "PreToolUse"
            }
        })
        #expect(AgentJournalAppendCapture.captures(in: commands.snapshot()).contains { capture in
            capture.kind == "agent.approval.requested"
                && capture.agentKey == "codex"
                && capture.workspaceId == workspaceId
                && capture.surfaceId == surfaceId
        })
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

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" > \"$CMUX_TEST_ARGS\"",
            "printf '%s\\n' \"$CMUX_CODEX_PID\" > \"$CMUX_TEST_PID\"",
            "cat > \"$CMUX_TEST_STDIN\"",
            "sleep 4",
            "printf done > \"$CMUX_TEST_DONE\"",
        ])

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(!install.timedOut, Comment(rawValue: install.stderr))
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let command = try #require(
            codexHookEntries(in: codexHome).first { $0.eventName == "UserPromptSubmit" }?.command
        )
        let payload = #"{"session_id":"codex-session","prompt":"rename this workspace"}"#
        let run = runCodexHookProcess(
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
            timeout: 2
        )

        #expect(!run.timedOut, Comment(rawValue: run.stderr))
        #expect(run.status == 0, Comment(rawValue: run.stderr))
        #expect(run.stdout == "{}\n")
        #expect(waitForFile(capturedStdin, containing: payload, timeout: 1))
        #expect(waitForFile(capturedArgs, containing: "--socket /tmp/cmux-test.sock hooks codex prompt-submit", timeout: 1))
        #expect(waitForFile(capturedPID, containing: "4242", timeout: 1))
        #expect(waitForFile(doneFile, containing: "done", timeout: 6))
    }

    @Test func codexHookClockDoesNotEmitWhenStateCommitFails() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-clock-commit-failure-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(!install.timedOut, Comment(rawValue: install.stderr))
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let promptHook = try #require(
            codexHookEntries(in: codexHome).first { $0.eventName == "UserPromptSubmit" }
        )
        let clockShell = try agentHookCaptureClockShell(commandBody: promptHook.body)
        let clockDirectory = root.appendingPathComponent("cmux-agent-hook-clock-v2", isDirectory: true)
        let stateDirectory = clockDirectory.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stateDirectory.path)

        let run = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", clockShell],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": root.path,
            ],
            timeout: 3
        )

        #expect(!run.timedOut, Comment(rawValue: run.stderr))
        #expect(
            run.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "A failed atomic state commit must not emit an uncommitted ordering timestamp"
        )
    }

    @Test func codexInstalledStopHookReturnsBeforeSlowCmuxCommandFinishes() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stop-hook-async-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux", isDirectory: false)
        let capturedStdin = root.appendingPathComponent("hook-stdin.json", isDirectory: false)
        let capturedArgs = root.appendingPathComponent("hook-args.txt", isDirectory: false)
        let capturedPID = root.appendingPathComponent("hook-pid.txt", isDirectory: false)
        let doneFile = root.appendingPathComponent("hook-done.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" > \"$CMUX_TEST_ARGS\"",
            "printf '%s\\n' \"$CMUX_CODEX_PID\" > \"$CMUX_TEST_PID\"",
            "cat > \"$CMUX_TEST_STDIN\"",
            "sleep 2",
            "printf done > \"$CMUX_TEST_DONE\"",
        ])

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(!install.timedOut, Comment(rawValue: install.stderr))
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let command = try #require(
            codexHookEntries(in: codexHome).first { $0.eventName == "Stop" }?.command
        )
        let payload = #"{"session_id":"codex-session","stop_hook_active":false}"#
        let run = runCodexHookProcess(
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
        #expect(waitForFile(capturedArgs, containing: "--socket /tmp/cmux-test.sock hooks codex stop", timeout: 1))
        #expect(waitForFile(capturedPID, containing: "4242", timeout: 1))
        #expect(waitForFile(doneFile, containing: "done", timeout: 3))
    }

    @Test func codexFireAndForgetWatchdogReapsItsTimerProcess() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-watchdog-reap-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let fakeCLI = binDirectory.appendingPathComponent("cmux", isDirectory: false)
        let fakeSleep = binDirectory.appendingPathComponent("sleep", isDirectory: false)
        let sleepPIDFile = root.appendingPathComponent("watchdog-sleep-pid.txt", isDirectory: false)
        let childDoneFile = root.appendingPathComponent("hook-child-done.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "cat >/dev/null",
            "attempt=0",
            "while [ ! -s \"$CMUX_TEST_SLEEP_PID\" ] && [ \"$attempt\" -lt 100 ]; do /bin/sleep 0.01; attempt=$((attempt + 1)); done",
            "printf done > \"$CMUX_TEST_CHILD_DONE\"",
        ])
        try makeCodexHookExecutableShellFile(at: fakeSleep, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$$\" > \"$CMUX_TEST_SLEEP_PID\"",
            "exec /usr/bin/tail -f /dev/null",
        ])

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(!install.timedOut, Comment(rawValue: install.stderr))
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let command = try #require(
            codexHookEntries(in: codexHome).first { $0.eventName == "UserPromptSubmit" }?.command
        )
        let run = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            environment: [
                "HOME": root.path,
                "PATH": "\(binDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": root.path,
                "CMUX_SURFACE_ID": "surface-123",
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_CODEX_PID": "4242",
                "CMUX_TEST_SLEEP_PID": sleepPIDFile.path,
                "CMUX_TEST_CHILD_DONE": childDoneFile.path,
            ],
            standardInput: #"{"session_id":"codex-session","prompt":"run"}"#,
            timeout: 2
        )

        #expect(!run.timedOut, Comment(rawValue: run.stderr))
        #expect(run.status == 0, Comment(rawValue: run.stderr))
        #expect(run.stdout == "{}\n")
        #expect(waitForFile(sleepPIDFile, containing: "\n", timeout: 1))
        #expect(waitForFile(childDoneFile, containing: "done", timeout: 1))

        let sleepPIDText = try String(contentsOf: sleepPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sleepPID = try #require(Int32(sleepPIDText))
        defer { _ = Darwin.kill(sleepPID, SIGKILL) }
        #expect(
            waitForConditionBlocking(timeout: 1) {
                Darwin.kill(sleepPID, 0) == -1 && errno == ESRCH
            },
            "The watchdog timer process \(sleepPID) outlived its completed hook invocation"
        )
    }

    @Test func codexTranscriptMonitorReplayUsesItsFreshEventTime() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-replay-time-(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-mon")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-monitor-replay-session"
        let turnId = "codex-monitor-replay-turn"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let transcriptURL = root.appendingPathComponent("transcript.jsonl")
        // Keep the persisted fixture deterministic while remaining inside the
        // production parser's supported epoch range.
        let inheritedEventTime: TimeInterval = 1_700_000_000
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        try """
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"\(turnId)"}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"\(turnId)","last_agent_message":"done"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "pid": Int(ProcessInfo.processInfo.processIdentifier),
                    "agentLifecycle": "running",
                    "runtimeStatus": "running",
                    "runtimeStatusEventTime": inheritedEventTime - 1,
                    "activePromptDepth": 1,
                    "activePromptTurnId": turnId,
                    "activePromptTurnIds": [turnId],
                    "lastPromptTurnId": turnId,
                    "startedAt": inheritedEventTime - 1,
                    "updatedAt": inheritedEventTime - 1,
                ],
            ],
        ], options: [.prettyPrinted, .sortedKeys]).write(to: stateURL, options: .atomic)
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 16
        )

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "codex", "monitor",
                "--workspace", workspaceId,
                "--surface", surfaceId,
                "--session", sessionId,
                "--turn", turnId,
                "--transcript", transcriptURL.path,
            ],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "TMPDIR": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_AGENT_HOOK_CAPTURED_AT": AgentHookWireFormat.eventTime(inheritedEventTime),
                "CMUX_CODEX_PID": "\(ProcessInfo.processInfo.processIdentifier)",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 10
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionId] as? [String: Any])
        let replayEventTime = try #require(session["runtimeStatusEventTime"] as? Double)
        #expect(
            replayEventTime > inheritedEventTime,
            "The monitor's completion replay must use its fresh sample, not the monitor's inherited start timestamp"
        )
        #expect(commands.snapshot().contains { $0.hasPrefix("set_status codex Idle ") })
    }

    @Test func codexDisabledInstalledStopConsumesPayloadBeforeReturning() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stop-disabled-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(!install.timedOut, Comment(rawValue: install.stderr))
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let stopCommand = try #require(
            codexHookEntries(in: codexHome).first { $0.eventName == "Stop" }?.command
        )
        let run = runCodexHookProcess(
            executablePath: "/bin/bash",
            arguments: [
                "-o", "pipefail", "-c",
                #"/bin/dd if=/dev/zero bs=1048576 count=8 2>/dev/null | CMUX_CODEX_HOOKS_DISABLED=1 "$CMUX_TEST_HOOK" >/dev/null"#,
            ],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_TEST_HOOK": stopCommand,
            ],
            timeout: 5
        )

        #expect(!run.timedOut, Comment(rawValue: run.stderr))
        #expect(
            run.status == 0,
            "The disabled Stop hook must drain stdin so Codex can finish writing its payload without EPIPE"
        )
    }

    @Test func codexWrapperStopScriptCannotBeOverwrittenByAnOlderGenerator() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stop-versioned-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let emit = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(!emit.timedOut, Comment(rawValue: emit.stderr))
        #expect(emit.status == 0, Comment(rawValue: emit.stderr))
        #expect(emit.stdout.contains("hooks.Stop="))
        #expect(emit.stdout.contains("timeout=10000"))

        let hooksDirectory = root
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        let generatedStopScript = try #require(
            FileManager.default
                .contentsOfDirectory(
                    at: hooksDirectory,
                    includingPropertiesForKeys: nil
                )
                .first { $0.lastPathComponent.hasSuffix("-stop.sh") }
        )
        let legacyStopScript = hooksDirectory
            .appendingPathComponent("cmux-codex-hook-stop.sh", isDirectory: false)
        #expect(
            generatedStopScript != legacyStopScript,
            "A content-addressed path prevents an older cmux build from replacing this script"
        )

        let generatedContents = try String(contentsOf: generatedStopScript, encoding: .utf8)
        try "#!/bin/sh\necho '{}'\n".write(
            to: legacyStopScript,
            atomically: true,
            encoding: .utf8
        )
        #expect(try String(contentsOf: generatedStopScript, encoding: .utf8) == generatedContents)
    }

    @Test func codexHookInstallReplacesLegacyGeneratedScriptPath() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stop-legacy-path-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let hooksDirectory = root
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyStopScript = hooksDirectory
            .appendingPathComponent("cmux-codex-hook-stop.sh", isDirectory: false)
        try makeCodexHookExecutableShellFile(at: legacyStopScript, lines: [
            "#!/bin/sh",
            "echo '{}'",
        ])
        let legacyHookJSON: [String: Any] = [
            "hooks": [
                "Stop": [
                    [
                        "hooks": [
                            [
                                "command": legacyStopScript.path,
                                "timeout": 10000,
                                "type": "command",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: legacyHookJSON,
            options: [.prettyPrinted, .sortedKeys]
        )
        .write(
            to: codexHome.appendingPathComponent("hooks.json", isDirectory: false),
            options: .atomic
        )

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(!install.timedOut, Comment(rawValue: install.stderr))
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let stopHooks = try codexHookEntries(in: codexHome)
            .filter { $0.eventName == "Stop" }
        #expect(stopHooks.count == 1)
        #expect(stopHooks.first?.command != legacyStopScript.path)
        #expect(stopHooks.first?.body.contains("cat >/dev/null") == true)
    }

    @Test func codexHookInstallPreservesUnrecognizedGeneratedLookingScriptPath() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-unrecognized-path-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let hooksDirectory = root
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let userScript = hooksDirectory
            .appendingPathComponent("cmux-codex-hook-unrecognized.sh", isDirectory: false)
        try makeCodexHookExecutableShellFile(at: userScript, lines: [
            "#!/bin/sh",
            "echo user-hook",
        ])
        let userHookJSON: [String: Any] = [
            "hooks": [
                "Stop": [
                    [
                        "hooks": [
                            [
                                "command": userScript.path,
                                "timeout": 10000,
                                "type": "command",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: userHookJSON,
            options: [.prettyPrinted, .sortedKeys]
        )
        .write(
            to: codexHome.appendingPathComponent("hooks.json", isDirectory: false),
            options: .atomic
        )

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(!install.timedOut, Comment(rawValue: install.stderr))
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let stopHooks = try codexHookEntries(in: codexHome)
            .filter { $0.eventName == "Stop" }
        #expect(stopHooks.contains { $0.command == userScript.path })
        #expect(stopHooks.contains { $0.command != userScript.path })
    }

    @Test func codexInstalledAsyncStopDoesNotMarkNewerTurnIdle() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-installed-stale-stop-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-inst")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-installed-stale-stop-session"
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 24
        )

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(!install.timedOut, Comment(rawValue: install.stderr))
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let promptCommand = try #require(
            codexHookEntries(in: codexHome).first { $0.eventName == "UserPromptSubmit" }?.command
        )
        let stopCommand = try #require(
            codexHookEntries(in: codexHome).first { $0.eventName == "Stop" }?.command
        )
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": codexHome.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "TMPDIR": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_BUNDLED_CLI_PATH": cliPath,
            "CMUX_CODEX_PID": "4242",
        ]

        let oldPrompt = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", promptCommand],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"old"}"#,
            timeout: 3
        )
        #expect(oldPrompt.status == 0, Comment(rawValue: oldPrompt.stderr))
        #expect(oldPrompt.stdout == "{}\n")
        #expect(waitForConditionBlocking(timeout: 2) {
            commands.snapshot().contains { $0.hasPrefix("set_status codex Running ") }
        })

        let currentPrompt = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", promptCommand],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"current"}"#,
            timeout: 3
        )
        #expect(currentPrompt.status == 0, Comment(rawValue: currentPrompt.stderr))
        #expect(currentPrompt.stdout == "{}\n")
        #expect(waitForConditionBlocking(timeout: 2) {
            let snapshot = commands.snapshot()
            return snapshot.contains { $0.hasPrefix("clear_notifications ") }
                && snapshot.contains { $0.hasPrefix("set_status codex Running ") }
        })

        let staleStopStart = commands.snapshot().count
        let staleStop = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", stopCommand],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(root.path)","hook_event_name":"Stop","last_assistant_message":"old done"}"#,
            timeout: 3
        )
        #expect(staleStop.status == 0, Comment(rawValue: staleStop.stderr))
        #expect(staleStop.stdout == "{}\n")
        #expect(waitForConditionBlocking(timeout: 2) {
            commands.snapshot().count > staleStopStart
        })

        let staleStopCommands = Array(commands.snapshot().dropFirst(staleStopStart))
        #expect(
            !staleStopCommands.contains {
                $0.hasPrefix("notify_target") || ($0.hasPrefix("set_status codex ") && $0.contains(" Idle "))
            },
            "An installed async Stop from an older turn must not notify or mark a newer running turn idle, saw \(staleStopCommands)"
        )
    }

    @Test func codexPromptSubmitDoesNotReviveStoppedTurn() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stale-prompt-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-stale")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
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
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 8
        )

        let result = runCodexHookProcess(
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
        #expect(!sentCommands.contains { codexHookJSONObject($0)?["method"] as? String == "feed.push" })
        #expect(!sentCommands.contains { codexHookJSONObject($0)?["method"] as? String == "surface.resume.set" })

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

    @Test func codexOlderRunningEventDoesNotOverwriteNewerIdleStop() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-out-of-order-prompt-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-order")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-out-of-order-session"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let idleStopEventTime: TimeInterval = 1_700_000_200
        let staleRunningEventTime: TimeInterval = 1_700_000_100
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
                    "runtimeStatusEventTime": idleStopEventTime,
                    "lastPromptTurnId": "turn-done",
                    "startedAt": idleStopEventTime,
                    "updatedAt": idleStopEventTime,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 8
        )

        let result = runCodexHookProcess(
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
            standardInput: "{\"session_id\":\"\(sessionId)\",\"turn_id\":\"turn-before-stop\",\"cwd\":\"\(root.path)\",\"hook_event_name\":\"UserPromptSubmit\",\"timestamp\":\(staleRunningEventTime),\"prompt\":\"late running\"}",
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let sentCommands = commands.snapshot()
        #expect(!sentCommands.contains { $0.hasPrefix("set_status codex Running ") })
        #expect(!sentCommands.contains { $0.hasPrefix("set_agent_lifecycle codex running ") })
        #expect(!sentCommands.contains { $0.hasPrefix("clear_notifications ") })

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionId] as? [String: Any])
        #expect(session["agentLifecycle"] as? String == "idle")
        #expect(session["runtimeStatus"] as? String == "idle")
        #expect(session["runtimeStatusEventTime"] as? Double == idleStopEventTime)
    }

    @Test func codexStopIgnoresLiveStaleSiblingWithoutActiveTurn() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stale-sibling-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-sib")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let staleSurfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "codex-current-session"
        let staleSessionId = "codex-stale-sibling-session"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let livePID = Int(ProcessInfo.processInfo.processIdentifier)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let eventTime: TimeInterval = 1_700_000_200
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "pid": livePID,
                    "agentLifecycle": "running",
                    "runtimeStatus": "running",
                    "activePromptDepth": 1,
                    "activePromptTurnId": "turn-current",
                    "activePromptTurnIds": ["turn-current"],
                    "lastPromptTurnId": "turn-current",
                    "runtimeStatusEventTime": eventTime - 1,
                    "startedAt": eventTime - 1,
                    "updatedAt": eventTime - 1,
                ],
                staleSessionId: [
                    "sessionId": staleSessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": staleSurfaceId,
                    "cwd": root.path,
                    "pid": livePID,
                    "agentLifecycle": "running",
                    "runtimeStatus": "running",
                    "lastPromptTurnId": "turn-stale",
                    "runtimeStatusEventTime": eventTime - 2,
                    "startedAt": eventTime - 600,
                    "updatedAt": eventTime - 600,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 12
        )

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CODEX_PID": "\(livePID)",
            ],
            standardInput: "{\"session_id\":\"\(sessionId)\",\"turn_id\":\"turn-current\",\"cwd\":\"\(root.path)\",\"hook_event_name\":\"Stop\",\"timestamp\":\(eventTime),\"last_assistant_message\":\"done\"}",
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let sentCommands = commands.snapshot()
        #expect(
            sentCommands.contains { $0.hasPrefix("set_status codex Idle ") },
            "A live but inactive stale sibling must not veto Idle: \(sentCommands)"
        )

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionId] as? [String: Any])
        #expect(session["agentLifecycle"] as? String == "idle")
        #expect(session["runtimeStatus"] as? String == "idle")
    }

    @Test func codexSessionStartDoesNotOverwriteExistingTurnState() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stale-start-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-start")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
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
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 8
        )

        let result = runCodexHookProcess(
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
        #expect(!AgentJournalAppendCapture.contains(sentCommands, kind: "agent.session.started", agentKey: "codex"))
        #expect(!sentCommands.contains { codexHookJSONObject($0)?["method"] as? String == "feed.push" })
        #expect(!sentCommands.contains { codexHookJSONObject($0)?["method"] as? String == "surface.resume.set" })

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
        let socketPath = makeCodexHookSocketPath("codex-fresh")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
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
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 8
        )

        let result = runCodexHookProcess(
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
        #expect(AgentJournalAppendCapture.contains(sentCommands, kind: "agent.session.started", agentKey: "codex"))
        #expect(sentCommands.contains { codexHookJSONObject($0)?["method"] as? String == "surface.resume.set" })

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
        let latePrompt = runCodexHookProcess(
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
        #expect(!commandsAfterLatePrompt.contains { codexHookJSONObject($0)?["method"] as? String == "feed.push" })
        #expect(!commandsAfterLatePrompt.contains { codexHookJSONObject($0)?["method"] as? String == "surface.resume.set" })
    }

    @Test func codexSessionStartDoesNotReviveCompletedTurnFromSamePID() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-same-pid-start-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-same")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
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
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "pid": 4242,
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
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 8
        )

        let result = runCodexHookProcess(
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
        #expect(!AgentJournalAppendCapture.contains(sentCommands, kind: "agent.session.started", agentKey: "codex"))
        #expect(!sentCommands.contains { codexHookJSONObject($0)?["method"] as? String == "surface.resume.set" })

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

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
    }

    private func injectedCodexHookEventNames(_ output: String) -> [String] {
        output.split(separator: "\0").compactMap { argument in
            guard argument.hasPrefix("hooks."),
                  let equals = argument.firstIndex(of: "=") else {
                return nil
            }
            return String(argument[argument.index(argument.startIndex, offsetBy: "hooks.".count)..<equals])
        }
    }
}
