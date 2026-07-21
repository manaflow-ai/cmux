import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CLIClaudeHookTimeoutRegressionTests {
    @Test("Claude prompt admission does not wait for cmux delivery")
    func promptSubmitReturnsBeforeSlowDeliveryFinishes() throws {
        let fileManager = FileManager.default
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let wrapper = repositoryRoot.appendingPathComponent(
            "Resources/bin/cmux-claude-wrapper",
            isDirectory: false
        )
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-claude-prompt-hook-\(UUID().uuidString)",
            isDirectory: true
        )
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let fakeCLI = binDirectory.appendingPathComponent("cmux", isDirectory: false)
        let fakeClaude = binDirectory.appendingPathComponent("claude", isDirectory: false)
        let settingsFile = root.appendingPathComponent("settings.json", isDirectory: false)
        let capturedStdin = root.appendingPathComponent("hook-stdin.json", isDirectory: false)
        let capturedArguments = root.appendingPathComponent("hook-args.txt", isDirectory: false)
        let capturedPID = root.appendingPathComponent("hook-pid.txt", isDirectory: false)
        let deliveryDone = root.appendingPathComponent("hook-done.txt", isDirectory: false)
        let socketPath = makeCodexHookSocketPath("claude")
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
            "printf '%s\\n' \"$*\" > \"$CMUX_TEST_ARGS\"",
            "printf '%s\\n' \"${CMUX_CLAUDE_PID:-}\" > \"$CMUX_TEST_PID\"",
            "cat > \"$CMUX_TEST_STDIN\"",
            "sleep 2",
            "printf done > \"$CMUX_TEST_DONE\"",
        ])
        try makeCodexHookExecutableShellFile(at: fakeClaude, lines: [
            "#!/bin/sh",
            "while [ \"$#\" -gt 0 ]; do",
            "  if [ \"$1\" = \"--settings\" ]; then shift; printf '%s' \"$1\" > \"$CMUX_TEST_SETTINGS\"; fi",
            "  shift",
            "done",
        ])

        let baseEnvironment = [
            "HOME": root.path,
            "PATH": "\(binDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": root.path,
            "CMUX_SURFACE_ID": "surface-8535",
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
            "CMUX_CUSTOM_CLAUDE_PATH": fakeClaude.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_TEST_REAL_CLI": cliPath,
            "CMUX_TEST_SETTINGS": settingsFile.path,
            "CMUX_TEST_STDIN": capturedStdin.path,
            "CMUX_TEST_ARGS": capturedArguments.path,
            "CMUX_TEST_PID": capturedPID.path,
            "CMUX_TEST_DONE": deliveryDone.path,
        ]
        let wrapperRun = runCodexHookProcess(
            executablePath: wrapper.path,
            arguments: [],
            environment: baseEnvironment,
            timeout: 5
        )
        #expect(!wrapperRun.timedOut, Comment(rawValue: wrapperRun.stderr))
        #expect(wrapperRun.status == 0, Comment(rawValue: wrapperRun.stderr))

        let settings = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile)) as? [String: Any]
        )
        let hooks = try #require(settings["hooks"] as? [String: Any])
        let promptGroups = try #require(hooks["UserPromptSubmit"] as? [[String: Any]])
        let promptGroup = try #require(promptGroups.first)
        let promptHooks = try #require(promptGroup["hooks"] as? [[String: Any]])
        let promptHook = try #require(promptHooks.first)
        let promptCommand = try #require(promptHook["command"] as? String)
        #expect(promptHook["timeout"] as? Int == 5)
        try expectDeferredHook(
            hooks,
            event: "SessionStart",
            commandFragment: "hooks claude session-start"
        )
        try expectDeferredHook(
            hooks,
            event: "Stop",
            commandFragment: "hooks claude stop"
        )
        try expectDeferredHook(
            hooks,
            event: "Stop",
            commandFragment: "hooks feed --source claude"
        )
        try expectDeferredHook(
            hooks,
            event: "SubagentStop",
            commandFragment: "hooks feed --source claude"
        )
        try expectDeferredHook(
            hooks,
            event: "SessionEnd",
            commandFragment: "hooks claude session-end"
        )
        try expectDeferredHook(
            hooks,
            event: "Notification",
            commandFragment: "hooks claude notification"
        )
        try expectDeferredHook(
            hooks,
            event: "UserPromptSubmit",
            commandFragment: "hooks claude prompt-submit"
        )
        try expectDeferredHook(
            hooks,
            event: "PreToolUse",
            commandFragment: "hooks claude pre-tool-use"
        )
        try expectDeferredHook(
            hooks,
            event: "PostToolUse",
            commandFragment: "hooks claude push-notification"
        )
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

        let payload = #"{"session_id":"claude-session","turn_id":"turn-8535","hook_event_name":"UserPromptSubmit"}"#
        var hookEnvironment = baseEnvironment
        hookEnvironment["CMUX_CLAUDE_PID"] = "8535"
        let hookRun = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", promptCommand],
            environment: hookEnvironment,
            standardInput: payload,
            timeout: 0.75
        )

        #expect(!hookRun.timedOut, Comment(rawValue: hookRun.stderr))
        #expect(hookRun.status == 0, Comment(rawValue: hookRun.stderr))
        #expect(hookRun.stdout == "{}\n")
        #expect(waitForFile(capturedStdin, containing: payload, timeout: 1))
        #expect(
            waitForFile(
                capturedArguments,
                containing: "--socket \(socketPath) hooks claude prompt-submit",
                timeout: 1
            )
        )
        #expect(waitForFile(capturedPID, containing: "8535", timeout: 1))
        #expect(waitForFile(deliveryDone, containing: "done", timeout: 3))
    }

    private func expectDeferredHook(
        _ hooks: [String: Any],
        event: String,
        commandFragment: String
    ) throws {
        let groups = try #require(hooks[event] as? [[String: Any]])
        let matchingHook = groups.lazy.compactMap { group -> [String: Any]? in
            guard let entries = group["hooks"] as? [[String: Any]] else { return nil }
            return entries.first { ($0["command"] as? String)?.contains(commandFragment) == true }
        }.first
        let hook = try #require(matchingHook)
        #expect(hook["timeout"] as? Int == 5)
        #expect(hook["async"] == nil)
    }

    private func expectDirectHook(
        _ hooks: [String: Any],
        event: String,
        command: String,
        timeout: Int,
        isAsync: Bool = false
    ) throws {
        let groups = try #require(hooks[event] as? [[String: Any]])
        let matchingHook = groups.lazy.compactMap { group -> [String: Any]? in
            guard let entries = group["hooks"] as? [[String: Any]] else { return nil }
            return entries.first { $0["command"] as? String == command }
        }.first
        let hook = try #require(matchingHook)
        #expect(hook["timeout"] as? Int == timeout)
        if isAsync {
            #expect(hook["async"] as? Bool == true)
        } else {
            #expect(hook["async"] == nil)
        }
    }
}
