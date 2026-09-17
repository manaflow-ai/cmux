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
        #expect(sessionStartHooks.allSatisfy { $0.body.contains("hooks enqueue codex session-start") })
        #expect(sessionStartHooks.allSatisfy { $0.timeout == 5 })
        #expect(sessionStartHooks.allSatisfy { $0.body.contains("agent_pid=") && $0.body.contains("CMUX_CODEX_PID=") })
        #expect(promptHooks.count == 1, "Installer should collapse duplicate prompt hooks")
        #expect(promptHooks.allSatisfy { $0.body.contains("hooks enqueue codex prompt-submit") })
        #expect(promptHooks.allSatisfy { $0.timeout == 5 })
        #expect(promptHooks.allSatisfy { $0.body.contains("agent_pid=") && $0.body.contains("CMUX_CODEX_PID=") })
        #expect(stopHooks.count == 1, "Installer should install one stop hook")
        #expect(stopHooks.allSatisfy { $0.body.contains("hooks enqueue codex stop") })
        #expect(stopHooks.allSatisfy { $0.timeout == 5 })
        #expect(stopHooks.allSatisfy { $0.body.contains("agent_pid=") && $0.body.contains("CMUX_CODEX_PID=") })
        #expect([sessionStartHooks, promptHooks, stopHooks].flatMap { $0 }.allSatisfy {
            !$0.body.contains("nohup")
                && !$0.body.contains("sleep ")
                && !$0.body.contains(">/dev/null 2>&1 &")
        })
        let expectedFeedEvents: Set<String> = [
            "PreToolUse",
            "PermissionRequest",
            "PostToolUse",
            "PreCompact",
            "PostCompact",
            "SubagentStart",
            "SubagentStop",
        ]
        let feedHooksByEvent = Dictionary(
            uniqueKeysWithValues: hooks
                .filter { expectedFeedEvents.contains($0.eventName) }
                .map { ($0.eventName, $0) }
        )
        #expect(feedHooksByEvent.count == expectedFeedEvents.count)
        for event in ["PreToolUse", "PostToolUse"] {
            let hook = try #require(feedHooksByEvent[event])
            #expect(hook.body.contains("hooks enqueue codex \(event == "PreToolUse" ? "pre-tool-use" : "post-tool-use")"))
            #expect(!hook.body.contains("nohup"))
            #expect(!hook.body.contains(">/dev/null 2>&1 &"))
        }
        let permissionHook = try #require(feedHooksByEvent["PermissionRequest"])
        #expect(permissionHook.body.contains("hooks feed --source codex --event PermissionRequest"))
        #expect(permissionHook.body.contains("CMUX_CODEX_HOOK_PID"))
        #expect(permissionHook.timeout == 120)
        for event in ["PreCompact", "PostCompact", "SubagentStart", "SubagentStop"] {
            let hook = try #require(feedHooksByEvent[event])
            #expect(hook.body.contains("hooks feed --source codex --event \(event)"))
            #expect(!hook.body.contains("nohup sh -c"))
        }
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
        let generatedHookDirectory = root
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        for (event, subcommand) in [("SubagentStart", "subagent-start"), ("SubagentStop", "subagent-stop")] {
            let config = try #require(
                emittedArguments.first { $0.hasPrefix("hooks.\(event)=") }
            )
            #expect(config.contains("timeout=5000"))
            let script = try #require(
                FileManager.default
                    .contentsOfDirectory(at: generatedHookDirectory, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasSuffix("-\(subcommand).sh") }
            )
            let scriptBody = try String(contentsOf: script, encoding: .utf8)
            #expect(scriptBody.contains("hooks codex \(subcommand)"))
            #expect(!scriptBody.contains("hooks enqueue codex \(subcommand)"))
        }

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
            connectionLimit: 16,
            processBinding: CodexHookMockProcessBinding(
                processID: 4242,
                workspaceID: workspaceId,
                surfaceID: surfaceId
            )
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
                "CMUX_CODEX_PID": "4242",
                "CMUX_CODEX_HOOK_PID": "4242",
            ],
            standardInput: #"{"session_id":"codex-permission-session","cwd":"\#(root.path)","hook_event_name":"PermissionRequest","message":"approval required"}"#,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(waitForConditionBlocking(timeout: 3) {
            commands.snapshot().contains { command in
                guard let object = codexHookJSONObject(command),
                      object["method"] as? String == "feed.push",
                      let params = object["params"] as? [String: Any],
                      let event = params["event"] as? [String: Any] else {
                    return false
                }
                return event["hook_event_name"] as? String == "PreToolUse"
                    && event["_ppid"] as? Int == 4242
            }
        })
        #expect(waitForConditionBlocking(timeout: 3) {
            AgentJournalAppendCapture.captures(in: commands.snapshot()).contains { capture in
                capture.kind == "agent.approval.requested"
                    && capture.agentKey == "codex"
                    && capture.workspaceId == workspaceId
                    && capture.surfaceId == surfaceId
            }
        })
    }

    @Test func codexInstalledPromptUsesQueueAdmission() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-async-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux", isDirectory: false)
        let capturedStdin = root.appendingPathComponent("hook-stdin.json", isDirectory: false)
        let capturedArgs = root.appendingPathComponent("hook-args.txt", isDirectory: false)
        let capturedPID = root.appendingPathComponent("hook-pid.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" > \"$CMUX_TEST_ARGS\"",
            "printf '%s\\n' \"$CMUX_CODEX_PID\" > \"$CMUX_TEST_PID\"",
            "cat > \"$CMUX_TEST_STDIN\"",
            "printf '{}\\n'",
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
            ],
            standardInput: payload,
            timeout: 2
        )

        #expect(!run.timedOut, Comment(rawValue: run.stderr))
        #expect(run.status == 0, Comment(rawValue: run.stderr))
        #expect(run.stdout == "{}\n")
        #expect(waitForFile(capturedStdin, containing: payload, timeout: 1))
        #expect(waitForFile(capturedArgs, containing: "--socket /tmp/cmux-test.sock hooks enqueue codex prompt-submit", timeout: 1))
        #expect(waitForFile(capturedPID, containing: "4242", timeout: 1))
    }

    @Test func codexInstalledStopUsesQueueAdmission() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stop-hook-async-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux", isDirectory: false)
        let capturedStdin = root.appendingPathComponent("hook-stdin.json", isDirectory: false)
        let capturedArgs = root.appendingPathComponent("hook-args.txt", isDirectory: false)
        let capturedPID = root.appendingPathComponent("hook-pid.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" > \"$CMUX_TEST_ARGS\"",
            "printf '%s\\n' \"$CMUX_CODEX_PID\" > \"$CMUX_TEST_PID\"",
            "cat > \"$CMUX_TEST_STDIN\"",
            "printf '{}\\n'",
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
            ],
            standardInput: payload,
            timeout: 1
        )

        #expect(!run.timedOut, Comment(rawValue: run.stderr))
        #expect(run.status == 0, Comment(rawValue: run.stderr))
        #expect(run.stdout == "{}\n")
        #expect(waitForFile(capturedStdin, containing: payload, timeout: 1))
        #expect(waitForFile(capturedArgs, containing: "--socket /tmp/cmux-test.sock hooks enqueue codex stop", timeout: 1))
        #expect(waitForFile(capturedPID, containing: "4242", timeout: 1))
    }

    @Test func codexInstalledPreToolUseUsesQueueAdmission() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-pre-tool-use-queue-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux", isDirectory: false)
        let capturedStdin = root.appendingPathComponent("hook-stdin.json", isDirectory: false)
        let capturedArgs = root.appendingPathComponent("hook-args.txt", isDirectory: false)
        let capturedPID = root.appendingPathComponent("hook-pid.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" > \"$CMUX_TEST_ARGS\"",
            "printf '%s\\n' \"$CMUX_CODEX_PID\" > \"$CMUX_TEST_PID\"",
            "cat > \"$CMUX_TEST_STDIN\"",
            "printf '{}\\n'",
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
            codexHookEntries(in: codexHome).first { $0.eventName == "PreToolUse" }?.command
        )
        let payload = #"{"session_id":"codex-session","hook_event_name":"PreToolUse","tool_name":"Bash"}"#
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
            ],
            standardInput: payload,
            timeout: 2
        )

        #expect(!run.timedOut, Comment(rawValue: run.stderr))
        #expect(run.status == 0, Comment(rawValue: run.stderr))
        #expect(run.stdout == "{}\n")
        #expect(waitForFile(capturedStdin, containing: payload, timeout: 1))
        #expect(waitForFile(capturedArgs, containing: "--socket /tmp/cmux-test.sock hooks enqueue codex pre-tool-use", timeout: 1))
        #expect(waitForFile(capturedPID, containing: "4242", timeout: 1))
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
        #expect(emit.stdout.contains("timeout=5000"))

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

    @Test func codexInstalledHooksPreserveAdmissionOrder() throws {
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

        let currentPrompt = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", promptCommand],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"current"}"#,
            timeout: 3
        )
        #expect(currentPrompt.status == 0, Comment(rawValue: currentPrompt.stderr))
        #expect(currentPrompt.stdout == "{}\n")

        let staleStop = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", stopCommand],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(root.path)","hook_event_name":"Stop","last_assistant_message":"old done"}"#,
            timeout: 3
        )
        #expect(staleStop.status == 0, Comment(rawValue: staleStop.stderr))
        #expect(staleStop.stdout == "{}\n")
        let admissions = commands.snapshot()
            .compactMap(codexHookJSONObject)
            .filter { $0["method"] as? String == "agent.hook.enqueue" }
        #expect(admissions.count == 3)
        let params = admissions.compactMap { $0["params"] as? [String: Any] }
        #expect(params.compactMap { $0["subcommand"] as? String } == [
            "prompt-submit", "prompt-submit", "stop",
        ])
        #expect(params.compactMap { $0["payload"] as? String }.map { payload in
            if payload.contains("old-turn") { return "old-turn" }
            if payload.contains("current-turn") { return "current-turn" }
            return "unknown"
        } == ["old-turn", "current-turn", "old-turn"])
        #expect(params.allSatisfy { $0["socket_path"] as? String == socketPath })
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
            connectionLimit: 8,
            processBinding: CodexHookMockProcessBinding(
                processID: 2,
                workspaceID: workspaceId,
                surfaceID: surfaceId
            )
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
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rolloutDirectory = codexHome.appendingPathComponent(
            "sessions/2026/08/12",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let rollout: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "id": sessionId,
                "cwd": root.path,
                "source": "cli",
                "originator": "codex-tui",
            ],
        ]
        let rolloutData = try JSONSerialization.data(withJSONObject: rollout, options: [.sortedKeys])
        try rolloutData.write(
            to: rolloutDirectory.appendingPathComponent("rollout-\(sessionId).jsonl"),
            options: .atomic
        )
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
            connectionLimit: 8,
            processBinding: CodexHookMockProcessBinding(
                processID: 4242,
                workspaceID: workspaceId,
                surfaceID: surfaceId
            )
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
                "CODEX_HOME": codexHome.path,
                "CMUX_CODEX_PID": "4242",
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
            connectionLimit: 8,
            processBinding: CodexHookMockProcessBinding(
                processID: 4242,
                workspaceID: workspaceId,
                surfaceID: surfaceId
            )
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
