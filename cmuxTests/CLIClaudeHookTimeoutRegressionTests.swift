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
            timeout: 3
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
        let admittedEnvironment = try #require(params["environment"] as? [String: Any])
        #expect(admittedEnvironment["CMUX_SURFACE_ID"] as? String == "surface-8535")
        #expect(admittedEnvironment["CMUX_CLAUDE_PID"] as? String == "8535")
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
