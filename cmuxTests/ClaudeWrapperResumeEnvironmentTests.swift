import CMUXAgentLaunch
import Darwin
import Foundation
import Testing

@Suite struct ClaudeWrapperResumeEnvironmentTests {
    @Test func bundledCLIEmitsCompleteNativeClaudeHookMatrix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-hook-matrix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "claude", "inject-settings"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))

        let data = try #require(result.stdout.data(using: .utf8))
        let settings = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(settings["preferredNotifChannel"] as? String == "notifications_disabled")
        let hooks = try #require(settings["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == [
            "SessionStart", "UserPromptSubmit", "Stop", "SessionEnd", "Notification",
            "PreToolUse", "PostToolUse", "SubagentStop", "PermissionRequest",
        ])

        let queued: [(event: String, matcher: String, tag: String)] = [
            ("SessionStart", "", "session-start"),
            ("UserPromptSubmit", "", "prompt-submit"),
            ("Stop", "", "stop"),
            ("SessionEnd", "", "session-end"),
            ("Notification", "", "notification"),
            ("PostToolUse", "PushNotification", "push-notification"),
            ("SubagentStop", "", "feed-SubagentStop"),
        ]
        for expected in queued {
            let groups = try #require(hooks[expected.event] as? [[String: Any]])
            #expect(groups.count == 1)
            try expectNativeClaudeHook(
                try #require(groups.first),
                matcher: expected.matcher,
                filenameTag: expected.tag
            )
        }

        let preToolGroups = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(preToolGroups.count == 2)
        let cronGroup = try #require(preToolGroups.first)
        #expect(cronGroup["matcher"] as? String == "CronCreate")
        let cronHooks = try #require(cronGroup["hooks"] as? [[String: Any]])
        let cronHook = try #require(cronHooks.first)
        #expect(
            cronHook["command"] as? String
                == #""${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" hooks claude cron-create-guard"#
        )
        #expect(cronHook["timeout"] as? Int == 5)
        try expectNativeClaudeHook(
            preToolGroups[1],
            matcher: "",
            filenameTag: "pre-tool-use"
        )

        let permissionGroups = try #require(hooks["PermissionRequest"] as? [[String: Any]])
        #expect(permissionGroups.count == 1)
        let permissionHooks = try #require(permissionGroups[0]["hooks"] as? [[String: Any]])
        let permissionHook = try #require(permissionHooks.first)
        #expect(
            permissionHook["command"] as? String
                == #""${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" hooks feed --source claude"#
        )
        #expect(permissionHook["timeout"] as? Int == 125)
        #expect(!result.stdout.contains("auto-name"))
    }

    @Test func bundledClaudeWrapperScrubsSessionIdentityAndPreservesTrustBypassOnResume() throws {
        let fileManager = FileManager.default
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let wrapperURL = repoRoot.appendingPathComponent("Resources/bin/cmux-claude-wrapper", isDirectory: false)
        #expect(
            fileManager.isExecutableFile(atPath: wrapperURL.path),
            "Bundled cmux-claude-wrapper must exist and be executable for resume environment coverage"
        )
        guard fileManager.isExecutableFile(atPath: wrapperURL.path) else { return }

        let sandbox = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-resume-\(String(UUID().uuidString.prefix(8)))", isDirectory: true)
        let binDir = sandbox.appendingPathComponent("bin", isDirectory: true)
        let homeDir = sandbox.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: homeDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sandbox) }

        let socketURL = sandbox.appendingPathComponent("cmux.sock", isDirectory: false)
        let socketFD = try bindUnixSocket(at: socketURL.path)
        defer {
            Darwin.close(socketFD)
            unlink(socketURL.path)
        }

        let recordURL = sandbox.appendingPathComponent("record.txt", isDirectory: false)
        let environmentPolicy = ClaudeSessionEnvironmentPolicy()
        let sessionIdentityKeys = environmentPolicy.inheritedSessionIdentityKeys.sorted()
        let trustBypassKeys = environmentPolicy.inheritedTrustBypassKeys.sorted()
        let observedKeys = sessionIdentityKeys + trustBypassKeys
        try writeExecutable(
            binDir.appendingPathComponent("claude", isDirectory: false),
            """
            #!/usr/bin/env bash
            {
              printf 'argv=%s\\n' "$*"
              for key in \(observedKeys.joined(separator: " ")) CLAUDE_CODE_USE_VERTEX; do
                if value="$(printenv "$key")"; then
                  printf '%s=%s\\n' "$key" "$value"
                else
                  printf '%s=<unset>\\n' "$key"
                fi
              done
            } > \(shellQuotedForTest(recordURL.path))
            """
        )
        let fakeCmuxURL = binDir.appendingPathComponent("cmux", isDirectory: false)
        try writeExecutable(
            fakeCmuxURL,
            """
            #!/usr/bin/env bash
            if [[ "${1:-}" == "--socket" && "${3:-}" == "ping" ]]; then
              exit 0
            fi
            exit 1
            """
        )

        let process = Process()
        process.executableURL = wrapperURL
        process.arguments = ["--resume", "claude-session-123"]
        var environment = [
            "PATH": "\(binDir.path):/usr/bin:/bin",
            "HOME": homeDir.path,
            "TMPDIR": sandbox.path,
            "CMUX_SURFACE_ID": UUID().uuidString,
            "CMUX_SOCKET_PATH": socketURL.path,
            "CMUX_BUNDLED_CLI_PATH": fakeCmuxURL.path,
            "CLAUDE_CODE_USE_VERTEX": "1",
        ]
        for key in observedKeys {
            environment[key] = "inherited-parent-value"
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try runWithBoundedWait(process, shellDescription: "cmux-claude-wrapper --resume")

        let recorded = try String(contentsOf: recordURL, encoding: .utf8)
        #expect(recorded.contains("--settings"), Comment(rawValue: recorded))
        #expect(recorded.contains("--resume claude-session-123"), Comment(rawValue: recorded))
        for key in sessionIdentityKeys {
            #expect(recorded.contains("\(key)=<unset>"), Comment(rawValue: recorded))
        }
        for key in trustBypassKeys {
            #expect(recorded.contains("\(key)=inherited-parent-value"), Comment(rawValue: recorded))
        }
        #expect(recorded.contains("CLAUDE_CODE_USE_VERTEX=1"), Comment(rawValue: recorded))
    }

    @Test func bundledClaudeWrapperUsesGeneratedNativeHookSettings() throws {
        let fileManager = FileManager.default
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let wrapperURL = repoRoot.appendingPathComponent("Resources/bin/cmux-claude-wrapper", isDirectory: false)
        #expect(fileManager.isExecutableFile(atPath: wrapperURL.path))
        guard fileManager.isExecutableFile(atPath: wrapperURL.path) else { return }

        let sandbox = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-claude-native-hooks-\(String(UUID().uuidString.prefix(8)))", isDirectory: true)
        let binDir = sandbox.appendingPathComponent("bin", isDirectory: true)
        let homeDir = sandbox.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: homeDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sandbox) }

        let socketURL = sandbox.appendingPathComponent("cmux.sock", isDirectory: false)
        let socketFD = try bindUnixSocket(at: socketURL.path)
        defer {
            Darwin.close(socketFD)
            unlink(socketURL.path)
        }

        let claudeRecordURL = sandbox.appendingPathComponent("claude-argv.txt", isDirectory: false)
        let cmuxRecordURL = sandbox.appendingPathComponent("cmux-argv.txt", isDirectory: false)
        try writeExecutable(
            binDir.appendingPathComponent("claude", isDirectory: false),
            """
            #!/usr/bin/env bash
            printf '%s\n' "$@" > \(shellQuotedForTest(claudeRecordURL.path))
            """
        )
        let fakeCmuxURL = binDir.appendingPathComponent("cmux", isDirectory: false)
        try writeExecutable(
            fakeCmuxURL,
            """
            #!/usr/bin/env bash
            printf '%s\n' "$*" >> \(shellQuotedForTest(cmuxRecordURL.path))
            if [[ "${1:-}" == "--socket" && "${3:-}" == "ping" ]]; then
              exit 0
            fi
            if [[ "$*" == "hooks claude inject-settings" ]]; then
              if [[ "${CMUX_TEST_INVALID_CLAUDE_SETTINGS:-}" == "1" ]]; then
                printf '%s' '[]'
                exit 0
              fi
              printf '%s' '{"preferredNotifChannel":"notifications_disabled","hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"/tmp/cmux-native-sentinel","timeout":1}]}]}}'
              exit 0
            fi
            exit 1
            """
        )

        let process = Process()
        process.executableURL = wrapperURL
        process.environment = [
            "PATH": "\(binDir.path):/usr/bin:/bin",
            "HOME": homeDir.path,
            "TMPDIR": sandbox.path,
            "CMUX_SURFACE_ID": UUID().uuidString,
            "CMUX_SOCKET_PATH": socketURL.path,
            "CMUX_BUNDLED_CLI_PATH": fakeCmuxURL.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try runWithBoundedWait(process, shellDescription: "cmux-claude-wrapper native hook settings")

        let claudeArguments = try String(contentsOf: claudeRecordURL, encoding: .utf8)
        let cmuxArguments = try String(contentsOf: cmuxRecordURL, encoding: .utf8)
        #expect(
            cmuxArguments.contains("hooks claude inject-settings"),
            "The wrapper must ask the bundled CLI for content-addressed native hook settings: \(cmuxArguments)"
        )
        #expect(
            claudeArguments.contains("/tmp/cmux-native-sentinel"),
            "The wrapper must pass the generated settings to Claude: \(claudeArguments)"
        )

        let fallbackProcess = Process()
        fallbackProcess.executableURL = wrapperURL
        var fallbackEnvironment = process.environment ?? [:]
        fallbackEnvironment["CMUX_TEST_INVALID_CLAUDE_SETTINGS"] = "1"
        fallbackProcess.environment = fallbackEnvironment
        fallbackProcess.standardInput = FileHandle.nullDevice
        fallbackProcess.standardOutput = FileHandle.nullDevice
        fallbackProcess.standardError = FileHandle.nullDevice
        try runWithBoundedWait(
            fallbackProcess,
            shellDescription: "cmux-claude-wrapper invalid generated hook settings"
        )

        let fallbackArguments = try String(contentsOf: claudeRecordURL, encoding: .utf8)
        #expect(!fallbackArguments.contains("/tmp/cmux-native-sentinel"))
        #expect(fallbackArguments.contains("hooks claude session-start"))
        #expect(fallbackArguments.contains("hooks claude cron-create-guard"))
        #expect(fallbackArguments.contains("hooks feed --source claude"))
        #expect(fallbackArguments.contains("hooks claude auto-name"))
    }

    private func runWithBoundedWait(
        _ process: Process,
        shellDescription: String,
        timeout: TimeInterval = 30
    ) throws {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw TestFailure("\(shellDescription) did not exit within \(Int(timeout))s")
        }
        guard process.terminationStatus == 0 else {
            throw TestFailure("\(shellDescription) exited with status \(process.terminationStatus)")
        }
    }

    private func writeExecutable(_ url: URL, _ contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
                let pathBuffer = UnsafeMutableRawPointer(pathPointer).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuffer, pointer, maxPathLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        guard Darwin.listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        return fd
    }

    private func shellQuotedForTest(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func expectNativeClaudeHook(
        _ group: [String: Any],
        matcher: String,
        filenameTag: String
    ) throws {
        #expect(group["matcher"] as? String == matcher)
        let hooks = try #require(group["hooks"] as? [[String: Any]])
        #expect(hooks.count == 1)
        let hook = try #require(hooks.first)
        #expect(hook["type"] as? String == "command")
        #expect(hook["timeout"] as? Int == 1)
        #expect(hook["async"] == nil)
        let command = try #require(hook["command"] as? String)
        #expect(FileManager.default.isExecutableFile(atPath: command))
        let name = URL(fileURLWithPath: command).lastPathComponent
        let prefix = "cmux-claude-native-hook-\(filenameTag)-"
        #expect(name.hasPrefix(prefix))
        let digest = name.dropFirst(prefix.count)
        #expect(digest.count == 64)
        #expect(digest.allSatisfy(\.isHexDigit))
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
