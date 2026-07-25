import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CLIClaudeHookTimeoutRegressionTests {
    @Test("Claude launch fallback omits blocking lifecycle hooks")
    func settingsGenerationFailureInstallsOnlyDecisionHooks() throws {
        let fileManager = FileManager.default
        let wrapper = repositoryRoot.appendingPathComponent("Resources/bin/cmux-claude-wrapper")
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-claude-settings-deadline-\(UUID().uuidString)",
            isDirectory: true
        )
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let fakeCLI = binDirectory.appendingPathComponent("cmux")
        let fakeClaude = binDirectory.appendingPathComponent("claude")
        let capturedSettings = root.appendingPathComponent("settings.json")
        let socketPath = makeCodexHookSocketPath("claude-deadline")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? fileManager.removeItem(at: root)
        }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "if [ \"${1:-}\" = \"--socket\" ] && [ \"${3:-}\" = \"ping\" ]; then exit 0; fi",
            "if [ \"${1:-}\" = \"hooks\" ] && [ \"${2:-}\" = \"claude\" ] && [ \"${3:-}\" = \"inject-settings\" ]; then exec /bin/sleep 30; fi",
            "exit 1",
        ])
        try makeSettingsCapturingClaude(at: fakeClaude)

        let result = runCodexHookProcess(
            executablePath: wrapper.path,
            arguments: [],
            environment: wrapperEnvironment(
                root: root,
                binDirectory: binDirectory,
                cli: fakeCLI,
                claude: fakeClaude,
                settings: capturedSettings,
                socketPath: socketPath
            ),
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let settings = try settingsObject(at: capturedSettings)
        #expect(settings["preferredNotifChannel"] == nil)
        let hooks = try #require(settings["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(["PreToolUse", "PermissionRequest"]))
        try expectDirectHook(
            hooks,
            event: "PreToolUse",
            command: #""${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" hooks claude cron-create-guard"#,
            timeout: 5
        )
        try expectDirectHook(
            hooks,
            event: "PermissionRequest",
            command: #""${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" hooks feed --source claude"#,
            timeout: 125
        )
    }

    @Test("Claude non-decision hooks use bounded ordered admission")
    func generatedSettingsUseQueuedAdmissionAndPreserveDecisionHooks() throws {
        let fileManager = FileManager.default
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let wrapper = repositoryRoot.appendingPathComponent("Resources/bin/cmux-claude-wrapper")
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-claude-queued-hooks-\(UUID().uuidString)",
            isDirectory: true
        )
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let fakeCLI = binDirectory.appendingPathComponent("cmux")
        let fakeClaude = binDirectory.appendingPathComponent("claude")
        let capturedSettings = root.appendingPathComponent("settings.json")
        let socketPath = makeCodexHookSocketPath("claude-queue")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? fileManager.removeItem(at: root)
        }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "if [ \"${1:-}\" = \"--socket\" ] && [ \"${3:-}\" = \"ping\" ]; then exit 0; fi",
            "if [ \"${1:-}\" = \"hooks\" ] && [ \"${2:-}\" = \"claude\" ] && [ \"${3:-}\" = \"inject-settings\" ]; then exec \"$CMUX_TEST_REAL_CLI\" \"$@\"; fi",
            "exit 1",
        ])
        try makeSettingsCapturingClaude(at: fakeClaude)
        var environment = wrapperEnvironment(
            root: root,
            binDirectory: binDirectory,
            cli: fakeCLI,
            claude: fakeClaude,
            settings: capturedSettings,
            socketPath: socketPath
        )
        environment["CMUX_TEST_REAL_CLI"] = cliPath

        let result = runCodexHookProcess(
            executablePath: wrapper.path,
            arguments: [],
            environment: environment,
            timeout: 5
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))

        let settings = try settingsObject(at: capturedSettings)
        #expect(settings["preferredNotifChannel"] as? String == "notifications_disabled")
        let hooks = try #require(settings["hooks"] as? [String: Any])
        let queuedHooks = [
            ("SessionStart", "session-start"),
            ("Stop", "stop"),
            ("Stop", "feed"),
            ("SubagentStop", "feed"),
            ("SessionEnd", "session-end"),
            ("Notification", "notification"),
            ("UserPromptSubmit", "prompt-submit"),
            ("PreToolUse", "pre-tool-use"),
            ("PostToolUse", "push-notification"),
        ]
        for (event, subcommand) in queuedHooks {
            try expectQueuedHook(hooks, event: event, subcommand: subcommand)
        }
        try expectDirectHook(
            hooks,
            event: "PreToolUse",
            command: #""${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" hooks claude cron-create-guard"#,
            timeout: 5
        )
        try expectDirectHook(
            hooks,
            event: "PermissionRequest",
            command: #""${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" hooks feed --source claude"#,
            timeout: 125
        )
        try expectDirectHook(
            hooks,
            event: "Stop",
            command: #""${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" hooks claude auto-name"#,
            timeout: 120,
            isAsync: true
        )

        let promptCommand = try hookCommand(
            hooks,
            event: "UserPromptSubmit",
            containing: "hooks enqueue claude prompt-submit"
        )
        let capturedCommands = CodexHookCapturedSocketCommands()
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: capturedCommands,
            surfaceId: "surface-8535",
            connectionLimit: 2
        )
        let payload = #"{"session_id":"claude-session","turn_id":"turn-8535"}"#
        let hookResult = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", promptCommand],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SURFACE_ID": "surface-8535",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_BUNDLED_CLI_PATH": cliPath,
                "CMUX_CLAUDE_PID": "8535",
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "ANTHROPIC_BASE_URL": "https://proxy.example.test",
                "ANTHROPIC_API_KEY": "must-not-cross-admission",
            ],
            standardInput: payload,
            timeout: 2
        )
        #expect(!hookResult.timedOut, Comment(rawValue: hookResult.stderr))
        #expect(hookResult.status == 0, Comment(rawValue: hookResult.stderr))
        #expect(hookResult.stdout == "{}\n")
        let request = try #require(capturedCommands.snapshot().compactMap(codexHookJSONObject).first {
            $0["method"] as? String == "agent.hook.enqueue"
        })
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["agent"] as? String == "claude")
        #expect(params["subcommand"] as? String == "prompt-submit")
        #expect(params["payload"] as? String == payload)
        #expect(params["socket_path"] as? String == socketPath)
        #expect(params["relay_backed"] as? Bool == false)
        let admittedEnvironment = try #require(params["environment"] as? [String: Any])
        #expect(admittedEnvironment["CMUX_SURFACE_ID"] as? String == "surface-8535")
        #expect(admittedEnvironment["CMUX_CLAUDE_PID"] as? String == "8535")
        #expect(admittedEnvironment["ANTHROPIC_BASE_URL"] as? String == "https://proxy.example.test")
        #expect(admittedEnvironment["ANTHROPIC_API_KEY"] == nil)
    }

    @Test("Claude prompt hook fails open before its declared timeout")
    func promptAdmissionHasAShortInternalDeadline() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let settingsResult = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "claude", "inject-settings"],
            environment: [
                "HOME": FileManager.default.temporaryDirectory.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 2
        )
        #expect(settingsResult.status == 0, Comment(rawValue: settingsResult.stderr))
        let settings = try #require(
            JSONSerialization.jsonObject(with: Data(settingsResult.stdout.utf8)) as? [String: Any]
        )
        let hooks = try #require(settings["hooks"] as? [String: Any])
        let command = try hookCommand(
            hooks,
            event: "UserPromptSubmit",
            containing: "hooks enqueue claude prompt-submit"
        )

        let socketPath = makeCodexHookSocketPath("claude-stall")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let result = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            environment: [
                "HOME": FileManager.default.temporaryDirectory.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SURFACE_ID": "surface-8535-stalled",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_BUNDLED_CLI_PATH": cliPath,
                "CMUX_CLAUDE_PID": "8535",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"session_id":"stalled"}"#,
            timeout: 2.5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
    }

    @Test("Queue admission compacts oversized telemetry without losing identity")
    func queueAdmissionCompactsOversizedTelemetry() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let socketPath = makeCodexHookSocketPath("large-queue")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let capturedCommands = CodexHookCapturedSocketCommands()
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: capturedCommands,
            surfaceId: "surface-8535",
            connectionLimit: 1
        )
        let input: [String: Any] = [
            "session_id": "relay-session-8535",
            "turn_id": "relay-turn-8535",
            "cwd": "/remote/worktree",
            "tool_name": "Write",
            "tool_input": ["plan": String(repeating: "x", count: 80 * 1_024)],
        ]
        let data = try JSONSerialization.data(withJSONObject: input)
        let rawPayload = try #require(String(data: data, encoding: .utf8))
        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "hooks", "enqueue", "claude", "prompt-submit"],
            environment: [
                "HOME": FileManager.default.temporaryDirectory.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLAUDE_PID": "8535",
                "CMUX_SURFACE_ID": "surface-8535",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: rawPayload,
            timeout: 5
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let request = try #require(capturedCommands.snapshot().compactMap(codexHookJSONObject).first {
            $0["method"] as? String == "agent.hook.enqueue"
        })
        let params = try #require(request["params"] as? [String: Any])
        let compactPayload = try #require(params["payload"] as? String)

        #expect(compactPayload.utf8.count <= 64 * 1_024)
        let compact = try #require(
            JSONSerialization.jsonObject(with: Data(compactPayload.utf8)) as? [String: Any]
        )
        #expect(compact["session_id"] as? String == "relay-session-8535")
        #expect(compact["turn_id"] as? String == "relay-turn-8535")
        #expect(compact["cwd"] as? String == "/remote/worktree")
    }

    @Test("Queue admission fails open when stdin exceeds the finite ingress budget")
    func queueAdmissionRejectsPayloadBeyondIngressBudget() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let socketPath = makeCodexHookSocketPath("ingress-budget")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let capturedCommands = CodexHookCapturedSocketCommands()
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: capturedCommands,
            surfaceId: "surface-ingress-budget",
            connectionLimit: 1
        )
        let input: [String: Any] = [
            "session_id": "oversized-ingress",
            "hook_event_name": "Stop",
            "additional_details": String(repeating: "z", count: 1 * 1_024 * 1_024),
        ]
        let data = try JSONSerialization.data(withJSONObject: input)
        let rawPayload = try #require(String(data: data, encoding: .utf8))
        #expect(rawPayload.utf8.count > 1 * 1_024 * 1_024)

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", socketPath, "hooks", "enqueue", "claude", "stop",
            ],
            environment: [
                "HOME": FileManager.default.temporaryDirectory.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_SURFACE_ID": "surface-ingress-budget",
                "CMUX_CLAUDE_PID": "8535",
            ],
            standardInput: rawPayload,
            fileBackedStandardInput: true,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let request = try #require(capturedCommands.snapshot().compactMap(codexHookJSONObject).first {
            $0["method"] as? String == "agent.hook.enqueue"
        })
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["payload"] as? String == "{}")
    }

    @Test("Queue compaction preserves behavior-critical needs-input fields")
    func queueCompactionPreservesNeedsInputClassification() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let socketPath = makeCodexHookSocketPath("large-needs-input")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let capturedCommands = CodexHookCapturedSocketCommands()
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: capturedCommands,
            surfaceId: "surface-8535",
            connectionLimit: 2
        )
        let oversizedOptions: [[String: Any]] = (0..<1_400).map { index in
            ["label": "Option \(index) " + String(repeating: "x", count: 60)]
        }
        let oversizedPrompts: [[String: Any]] = (0..<1_400).map { index in
            [
                "prompt": "Prompt \(index) " + String(repeating: "y", count: 220),
                "tool": "Bash",
            ]
        }
        let cases: [(toolName: String, toolInput: [String: Any], summaryKey: String)] = [
            (
                "AskUserQuestion",
                [
                    "questions": [[
                        "question": "Which release channel?",
                        "header": "Channel",
                        "options": oversizedOptions,
                    ]],
                ],
                "questions"
            ),
            (
                "ExitPlanMode",
                [
                    "plan": "# Plan\n1. Preserve needs-input routing.",
                    "allowedPrompts": oversizedPrompts,
                ],
                "plan"
            ),
        ]

        for testCase in cases {
            let input: [String: Any] = [
                "session_id": "needs-input-\(testCase.toolName)",
                "cwd": "/remote/worktree",
                "permission_mode": "bypassPermissions",
                "hook_event_name": "PreToolUse",
                "tool_name": testCase.toolName,
                "tool_input": testCase.toolInput,
            ]
            let data = try JSONSerialization.data(withJSONObject: input)
            let rawPayload = try #require(String(data: data, encoding: .utf8))
            #expect(rawPayload.utf8.count > 64 * 1_024)

            let result = runCodexHookProcess(
                executablePath: cliPath,
                arguments: ["--socket", socketPath, "hooks", "enqueue", "claude", "pre-tool-use"],
                environment: [
                    "HOME": FileManager.default.temporaryDirectory.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "CMUX_CLAUDE_PID": "8535",
                    "CMUX_SURFACE_ID": "surface-8535",
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                ],
                standardInput: rawPayload,
                timeout: 5
            )

            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            let request = try #require(capturedCommands.snapshot().compactMap(codexHookJSONObject).last {
                $0["method"] as? String == "agent.hook.enqueue"
            })
            let params = try #require(request["params"] as? [String: Any])
            let compactPayload = try #require(params["payload"] as? String)
            #expect(compactPayload.utf8.count <= 64 * 1_024)
            let compact = try #require(
                JSONSerialization.jsonObject(with: Data(compactPayload.utf8)) as? [String: Any]
            )
            #expect(compact["tool_name"] as? String == testCase.toolName)
            #expect(compact["permission_mode"] as? String == "bypassPermissions")
            #expect(compact["hook_event_name"] as? String == "PreToolUse")
            let compactToolInput = try #require(compact["tool_input"] as? [String: Any])
            #expect(compactToolInput[testCase.summaryKey] != nil)
        }
    }

    @Test(
        "Queue compaction preserves Boolean lifecycle flags",
        arguments: [
            ("antigravity", "fullyIdle", false),
            ("pi", "cmux_notification_routed", true),
        ]
    )
    func queueCompactionPreservesBooleanLifecycleFlags(
        agent: String,
        flag: String,
        value: Bool
    ) throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let socketPath = makeCodexHookSocketPath("\(agent)-lifecycle-flags")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let capturedCommands = CodexHookCapturedSocketCommands()
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: capturedCommands,
            surfaceId: "surface-\(agent)-lifecycle-flags",
            connectionLimit: 1
        )
        let input: [String: Any] = [
            "session_id": "lifecycle-\(agent)",
            "hook_event_name": "Stop",
            flag: value,
            "additional_details": String(repeating: "z", count: 70 * 1_024),
        ]
        let data = try JSONSerialization.data(withJSONObject: input)
        let rawPayload = try #require(String(data: data, encoding: .utf8))
        #expect(rawPayload.utf8.count > 64 * 1_024)

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", socketPath, "hooks", "enqueue", agent, "stop",
            ],
            environment: [
                "HOME": FileManager.default.temporaryDirectory.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_SURFACE_ID": "surface-\(agent)-lifecycle-flags",
                "CMUX_\(agent.uppercased())_PID": "8535",
            ],
            standardInput: rawPayload,
            fileBackedStandardInput: true,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(
            result.stdout == "{}\n",
            Comment(rawValue: "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        )
        let commands = capturedCommands.snapshot()
        let request = try #require(commands.compactMap(codexHookJSONObject).last {
            guard $0["method"] as? String == "agent.hook.enqueue",
                  let params = $0["params"] as? [String: Any] else {
                return false
            }
            return params["agent"] as? String == agent
        }, Comment(rawValue: "captured commands:\n\(commands.joined(separator: "\n"))"))
        let params = try #require(request["params"] as? [String: Any])
        let compactPayload = try #require(params["payload"] as? String)
        #expect(compactPayload.utf8.count <= 64 * 1_024)
        let compact = try #require(
            JSONSerialization.jsonObject(with: Data(compactPayload.utf8)) as? [String: Any]
        )
        #expect(
            compact[flag] as? Bool == value,
            Comment(rawValue: compactPayload)
        )
    }

    @Test(
        "Pinned agent queue admission uses its explicit socket without ambient cmux target IDs",
        arguments: ["grok", "antigravity"]
    )
    func pinnedAgentQueueAdmissionUsesExplicitSocket(agent: String) throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let socketPath = makeCodexHookSocketPath("\(agent)-pinned")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let capturedCommands = CodexHookCapturedSocketCommands()
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: capturedCommands,
            surfaceId: "unused-pinned-surface",
            connectionLimit: 1
        )
        let payload = #"{"session_id":"pinned-session","hook_event_name":"Stop"}"#

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "hooks", "enqueue", agent, "stop"],
            environment: [
                "HOME": FileManager.default.temporaryDirectory.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: payload,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let request = try #require(capturedCommands.snapshot().compactMap(codexHookJSONObject).first {
            $0["method"] as? String == "agent.hook.enqueue"
        })
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["agent"] as? String == agent)
        #expect(params["subcommand"] as? String == "stop")
        #expect(params["payload"] as? String == payload)
        #expect(params["socket_path"] as? String == socketPath)
        let admittedEnvironment = try #require(params["environment"] as? [String: Any])
        #expect(admittedEnvironment["CMUX_SURFACE_ID"] == nil)
        #expect(admittedEnvironment["CMUX_WORKSPACE_ID"] == nil)
        let pidKey = "CMUX_\(agent.uppercased())_PID"
        #expect(
            admittedEnvironment[pidKey] as? String ==
                String(ProcessInfo.processInfo.processIdentifier)
        )
    }

    @Test(
        "Relay-origin delivery skips local PID and TTY routing",
        arguments: [("claude", "CMUX_CLAUDE_PID"), ("codex", "CMUX_CODEX_PID")]
    )
    func relayOriginSkipsLocalProcessRouting(agent: String, pidKey: String) throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-relay-hook-routing-\(agent)-\(UUID().uuidString)",
            isDirectory: true
        )
        let socketPath = makeCodexHookSocketPath("relay-route")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let capturedCommands = CodexHookCapturedSocketCommands()
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: capturedCommands,
            surfaceId: "22222222-2222-2222-2222-222222222222",
            connectionLimit: 16
        )
        let environment = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
            "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
            "CMUX_CLI_TTY_NAME": "ttys-local-collision",
            "CMUX_AGENT_HOOK_RELAY_ORIGIN": "1",
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            pidKey: "8535",
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", agent, "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"relay-session","source":"clear"}"#,
            timeout: 10
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))

        let socketCommands = capturedCommands.snapshot()
        let requests = socketCommands.compactMap(codexHookJSONObject)
        if agent == "claude" {
            let surfaceProbe = try #require(requests.first {
                $0["method"] as? String == "agent.resolve_delivery_target"
            })
            let params = try #require(surfaceProbe["params"] as? [String: Any])
            #expect(params["surface_id"] as? String == "22222222-2222-2222-2222-222222222222")
            #expect(params["pid"] == nil)
        } else {
            #expect(requests.contains { $0["method"] as? String == "surface.list" })
        }
        #expect(!requests.contains { $0["method"] as? String == "system.top" })
        #expect(!requests.contains { $0["method"] as? String == "debug.terminals" })
        #expect(!socketCommands.contains { $0.hasPrefix("set_agent_pid ") })
        #expect(!socketCommands.contains { $0.contains(" --pid=8535") })
        let deliveryTargetRequests = requests.filter {
            $0["method"] as? String == "agent.resolve_delivery_target"
        }
        #expect(deliveryTargetRequests.allSatisfy { request in
            (request["params"] as? [String: Any])?["pid"] == nil
        })
    }

    @Test("Relay-origin Codex stop ignores local transcript path collisions")
    func relayOriginCodexStopIgnoresLocalTranscriptPathCollisions() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-relay-codex-stop-\(UUID().uuidString)",
            isDirectory: true
        )
        let transcriptURL = root.appendingPathComponent("remote-rollout.jsonl", isDirectory: false)
        let socketPath = makeCodexHookSocketPath("relay-stop")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        {"timestamp":"2026-07-21T00:00:00.000Z","type":"session_meta","payload":{"id":"relay-codex-session","cwd":"/remote/worktree"}}
        {"timestamp":"2026-07-21T00:00:01.000Z","type":"event_msg","payload":{"type":"error","turn_id":"relay-turn","message":"Local collision must stay unread.","codex_error_info":"server_overloaded"}}
        {"timestamp":"2026-07-21T00:00:02.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"relay-turn","last_agent_message":null}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let capturedCommands = CodexHookCapturedSocketCommands()
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: capturedCommands,
            surfaceId: "22222222-2222-2222-2222-222222222222",
            connectionLimit: 24
        )
        let payload = """
        {"session_id":"relay-codex-session","turn_id":"relay-turn","transcript_path":"\(transcriptURL.path)","cwd":"/remote/worktree","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":null}
        """
        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_AGENT_HOOK_RELAY_ORIGIN": "1",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: payload,
            timeout: 10
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))

        let commands = capturedCommands.snapshot()
        #expect(!commands.contains { $0.contains("Local collision must stay unread.") })
        #expect(!commands.contains { $0.contains("set_status codex Codex error") })
        #expect(!commands.contains { $0.contains("--color=#FF453A") })
    }

    @Test("Actionable Feed decisions establish their delivery lane barrier before push")
    func actionableFeedDecisionWaitsForEarlierQueuedLifecycleWork() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-feed-decision-barrier-\(UUID().uuidString)",
            isDirectory: true
        )
        let socketPath = makeCodexHookSocketPath("feed-barrier")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let capturedCommands = CodexHookCapturedSocketCommands()
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: capturedCommands,
            surfaceId: surfaceID,
            connectionLimit: 4
        )
        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", socketPath,
                "hooks", "feed", "--source", "gemini", "--event", "PreToolUse",
            ],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_WORKSPACE_ID": workspaceID,
                "CMUX_SURFACE_ID": surfaceID,
                "CMUX_GEMINI_PID": "8535",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: """
            {"session_id":"decision-session","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"true"}}
            """,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let requests = capturedCommands.snapshot().compactMap(codexHookJSONObject)
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(
            Array(methods.prefix(2)) == ["agent.hook.barrier", "feed.push"],
            Comment(rawValue: String(describing: requests))
        )
        let barrier = try #require(requests.first {
            $0["method"] as? String == "agent.hook.barrier"
        })
        let params = try #require(barrier["params"] as? [String: Any])
        #expect(params["agent"] as? String == "gemini")
        let environment = try #require(params["environment"] as? [String: Any])
        #expect(environment["CMUX_WORKSPACE_ID"] as? String == workspaceID)
        #expect(environment["CMUX_SURFACE_ID"] as? String == surfaceID)
        #expect(environment["CMUX_GEMINI_PID"] as? String == "8535")
    }

    @Test("Direct Codex permission status waits for its queued lifecycle lane")
    func codexPermissionStatusWaitsForEarlierQueuedLifecycleWork() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-codex-decision-barrier-\(UUID().uuidString)",
            isDirectory: true
        )
        let socketPath = makeCodexHookSocketPath("codex-barrier")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let capturedCommands = CodexHookCapturedSocketCommands()
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: capturedCommands,
            surfaceId: surfaceID,
            connectionLimit: 8
        )
        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", socketPath,
                "hooks", "codex", "notification",
            ],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_WORKSPACE_ID": workspaceID,
                "CMUX_SURFACE_ID": surfaceID,
                "CMUX_CODEX_PID": "8535",
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: """
            {"session_id":"codex-decision-session","hook_event_name":"PermissionRequest","tool_name":"Write"}
            """,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let requests = capturedCommands.snapshot().compactMap(codexHookJSONObject)
        #expect(
            requests.first?["method"] as? String == "agent.hook.barrier",
            Comment(rawValue: String(describing: requests))
        )
        let params = try #require(requests.first?["params"] as? [String: Any])
        #expect(params["agent"] as? String == "codex")
        let environment = try #require(params["environment"] as? [String: Any])
        #expect(environment["CMUX_SURFACE_ID"] as? String == surfaceID)
        #expect(environment["CMUX_CODEX_PID"] as? String == "8535")
    }

    @Test("Custom agent installers emit bounded queue admission")
    func customAgentInstallersEmitBoundedQueueAdmission() throws {
        struct Producer {
            let agent: String
            let environment: [String: String]
            let artifact: URL
        }

        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-custom-agent-queue-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let opencodeRoot = root.appendingPathComponent("opencode", isDirectory: true)
        let piRoot = root.appendingPathComponent("pi", isDirectory: true)
        let ompRoot = root.appendingPathComponent("omp", isDirectory: true)
        let campfireRoot = root.appendingPathComponent("campfire", isDirectory: true)
        let ampHome = root.appendingPathComponent("amp-home", isDirectory: true)
        let producers = [
            Producer(
                agent: "opencode",
                environment: ["OPENCODE_CONFIG_DIR": opencodeRoot.path],
                artifact: opencodeRoot.appendingPathComponent("plugins/cmux-session.js")
            ),
            Producer(
                agent: "pi",
                environment: ["PI_CODING_AGENT_DIR": piRoot.path],
                artifact: piRoot.appendingPathComponent("extensions/cmux-session.ts")
            ),
            Producer(
                agent: "omp",
                environment: ["PI_CODING_AGENT_DIR": ompRoot.path],
                artifact: ompRoot.appendingPathComponent("extensions/cmux-omp-session.ts")
            ),
            Producer(
                agent: "campfire",
                environment: ["CAMPFIRE_CODING_AGENT_DIR": campfireRoot.path],
                artifact: campfireRoot.appendingPathComponent("extensions/cmux-campfire-session.ts")
            ),
            Producer(
                agent: "amp",
                environment: ["HOME": ampHome.path],
                artifact: ampHome.appendingPathComponent(".config/amp/plugins/cmux-session.ts")
            ),
        ]

        for producer in producers {
            var environment = [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
            environment.merge(producer.environment, uniquingKeysWith: { _, value in value })
            let result = runCodexHookProcess(
                executablePath: cliPath,
                arguments: ["hooks", producer.agent, "install", "--yes"],
                environment: environment,
                timeout: 5
            )
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            let source = try String(contentsOf: producer.artifact, encoding: .utf8)
            #expect(
                source.contains("[\"hooks\", \"enqueue\", \"\(producer.agent)\", subcommand]"),
                "\(producer.agent) lifecycle hooks must use the shared app queue"
            )
            #expect(
                source.contains("CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"),
                "\(producer.agent) queue admission must have an internal socket deadline"
            )
            #expect(
                !source.contains("[\"hooks\", \"\(producer.agent)\", subcommand]"),
                "\(producer.agent) must not retain a direct lifecycle delivery path"
            )
        }

        let piSource = try String(contentsOf: producers[1].artifact, encoding: .utf8)
        #expect(piSource.contains("[\"hooks\", \"feed\", \"--source\", \"pi\""))
        #expect(!piSource.contains("[\"hooks\", \"enqueue\", \"feed\""))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeSettingsCapturingClaude(at url: URL) throws {
        try makeCodexHookExecutableShellFile(at: url, lines: [
            "#!/bin/sh",
            "while [ \"$#\" -gt 0 ]; do",
            "  if [ \"$1\" = \"--settings\" ]; then shift; printf '%s' \"$1\" > \"$CMUX_TEST_SETTINGS\"; fi",
            "  shift",
            "done",
        ])
    }

    private func wrapperEnvironment(
        root: URL,
        binDirectory: URL,
        cli: URL,
        claude: URL,
        settings: URL,
        socketPath: String
    ) -> [String: String] {
        [
            "HOME": root.path,
            "PATH": "\(binDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": root.path,
            "CMUX_SURFACE_ID": "surface-8535",
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_BUNDLED_CLI_PATH": cli.path,
            "CMUX_CUSTOM_CLAUDE_PATH": claude.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_TEST_SETTINGS": settings.path,
        ]
    }

    private func settingsObject(at url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func hookCommand(
        _ hooks: [String: Any],
        event: String,
        containing fragment: String
    ) throws -> String {
        let groups = try #require(hooks[event] as? [[String: Any]])
        return try #require(groups.lazy.compactMap { group -> String? in
            guard let entries = group["hooks"] as? [[String: Any]] else { return nil }
            return entries.compactMap { $0["command"] as? String }.first { $0.contains(fragment) }
        }.first)
    }

    private func expectQueuedHook(
        _ hooks: [String: Any],
        event: String,
        subcommand: String
    ) throws {
        let command = try hookCommand(
            hooks,
            event: event,
            containing: "hooks enqueue claude \(subcommand)"
        )
        let groups = try #require(hooks[event] as? [[String: Any]])
        let hook = try #require(groups.lazy.compactMap { group -> [String: Any]? in
            guard let entries = group["hooks"] as? [[String: Any]] else { return nil }
            return entries.first { $0["command"] as? String == command }
        }.first)
        #expect(hook["timeout"] as? Int == 3)
        #expect(hook["async"] == nil)
        #expect(command.contains(#"--socket "$CMUX_SOCKET_PATH""#))
        #expect(command.contains("CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=1"))
        #expect(!command.contains("nohup"))
        #expect(!command.contains("sleep "))
        #expect(!command.contains("watchdog"))
        #expect(!command.contains(">/dev/null 2>&1 &"))
    }

    private func expectDirectHook(
        _ hooks: [String: Any],
        event: String,
        command: String,
        timeout: Int,
        isAsync: Bool = false
    ) throws {
        let groups = try #require(hooks[event] as? [[String: Any]])
        let hook = try #require(groups.lazy.compactMap { group -> [String: Any]? in
            guard let entries = group["hooks"] as? [[String: Any]] else { return nil }
            return entries.first { $0["command"] as? String == command }
        }.first)
        #expect(hook["timeout"] as? Int == timeout)
        #expect((hook["async"] as? Bool) == (isAsync ? true : nil))
        #expect(!(command.contains("hooks enqueue")))
    }
}
