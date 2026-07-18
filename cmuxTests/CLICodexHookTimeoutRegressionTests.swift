import Foundation
import Testing

@Suite(.serialized)
struct CLICodexHookTimeoutRegressionTests {
    @Test func codexWrapperUsesOneNativeClientForAllQueuedEvents() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-native-client-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("custom codex home", isDirectory: true)
        let hooksDirectory = root
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("native")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceID,
            connectionLimit: 7,
            droppedResponseCount: 1
        )
        let inject = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(!inject.timedOut, Comment(rawValue: inject.stderr))
        #expect(inject.status == 0, Comment(rawValue: inject.stderr))

        let expectedEvents = [
            "session-start", "prompt-submit", "stop",
            "pre-tool-use", "post-tool-use", "notification",
        ]
        let installedPaths = expectedEvents.map {
            hooksDirectory.appendingPathComponent("cmux-codex-hook-\($0).sh", isDirectory: false).path
        }
        let nativeClientPath = URL(fileURLWithPath: cliPath)
            .deletingLastPathComponent()
            .appendingPathComponent("cmux-codex-hook-client", isDirectory: false)
            .path
        #expect(FileManager.default.isExecutableFile(atPath: nativeClientPath))
        #expect(installedPaths.allSatisfy(codexHookExecutableIsMachO))

        let binaryPayload = Data([0x00, 0xFF, 0x0A, 0x22, 0x5C, 0x7F])
        let expectedEnvironment = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": #"/tmp/project \"quoted\"/日本語\\repo"#,
            "TMPDIR": root.path,
            "CODEX_HOME": codexHome.path,
            "CMUX_AGENT_HOOK_STATE_DIR": root.appendingPathComponent("state directory").path,
            "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS": "1",
            "CMUX_AGENT_LAUNCH_ARGV_B64": Data("codex\0resume\0session\0".utf8).base64EncodedString(),
            "CMUX_AGENT_LAUNCH_CWD": #"/tmp/project \"quoted\"/日本語\\repo"#,
            "CMUX_AGENT_LAUNCH_EXECUTABLE": #"/tmp/bin/codex \"custom\"\\版本"#,
            "CMUX_AGENT_LAUNCH_KIND": "codex",
            "CMUX_AGENT_MANAGED_SUBAGENT": "1",
            "CMUX_BUNDLE_ID": "com.cmuxterm.app.debug.native",
            "CMUX_CODEX_PID": "4242",
            "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS": "1",
            "CMUX_SURFACE_ID": surfaceID,
            "CMUX_TAG": "native",
            "CMUX_WORKSPACE_ID": workspaceID,
            "CMUX_SOCKET_PATH": socketPath,
        ]

        for (index, path) in installedPaths.enumerated() {
            var environment = expectedEnvironment
            environment["CMUX_SOCKET_CAPABILITY"] = "test-capability"
            environment["CMUX_BUNDLED_CLI_PATH"] = cliPath
            environment["CMUX_AGENT_HOOK_DELIVERY_ID"] = "native-event-\(index)"
            let payload = index == 0 ? binaryPayload : Data("payload-\(expectedEvents[index])".utf8)
            let result = runCodexHookProcess(
                executablePath: path,
                arguments: [],
                environment: environment,
                standardInputData: payload,
                timeout: 3
            )
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
        }

        let rawRequests = commands.snapshot()
        #expect(rawRequests.count == 7)
        #expect(rawRequests.allSatisfy { $0.hasPrefix("_cmux_capability_v1 test-capability ") })
        let requests = try rawRequests.map { try #require(codexHookJSONObject($0)) }
        let parameters = try requests.map { request in
            try #require(request["params"] as? [String: Any])
        }
        #expect(parameters[0]["delivery_id"] as? String == "native-event-0")
        #expect(parameters[1]["delivery_id"] as? String == "native-event-0")
        #expect(Array(parameters.dropFirst().compactMap { $0["subcommand"] as? String }) == expectedEvents)
        let firstPayload = try #require(parameters[0]["payload_b64"] as? String)
        #expect(Data(base64Encoded: firstPayload) == binaryPayload)
        let encodedEnvironment = try #require(parameters[0]["environment_b64"] as? String)
        #expect(decodeNULSeparatedEnvironment(encodedEnvironment) == expectedEnvironment)
    }

    @Test func codexNativeClientReplaysExactInputThroughStableFallback() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-native-fallback-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let hooksDirectory = root
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux-fallback", isDirectory: false)
        let capturedInput = root.appendingPathComponent("fallback-input.bin", isDirectory: false)
        let capturedID = root.appendingPathComponent("fallback-id.txt", isDirectory: false)
        let capturedArgs = root.appendingPathComponent("fallback-args.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let inject = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(inject.status == 0, Comment(rawValue: inject.stderr))
        let hookPath = hooksDirectory
            .appendingPathComponent("cmux-codex-hook-prompt-submit.sh", isDirectory: false)
            .path
        #expect(codexHookExecutableIsMachO(hookPath))

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s' \"$CMUX_AGENT_HOOK_DELIVERY_ID\" > \"$CMUX_TEST_ID\"",
            "printf '%s' \"$*\" > \"$CMUX_TEST_ARGS\"",
            "cat > \"$CMUX_TEST_INPUT\"",
        ])
        let payload = Data([0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF, 0x0A])
        let deliveryID = "native-stable-fallback"
        let result = runCodexHookProcess(
            executablePath: hookPath,
            arguments: [],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SURFACE_ID": "surface-fallback",
                "CMUX_SOCKET_PATH": "/tmp/cmux-native-missing.sock",
                "CMUX_SOCKET_CAPABILITY": "test-capability",
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_CODEX_PID": "4242",
                "CMUX_AGENT_HOOK_DELIVERY_ID": deliveryID,
                "CMUX_TEST_ID": capturedID.path,
                "CMUX_TEST_ARGS": capturedArgs.path,
                "CMUX_TEST_INPUT": capturedInput.path,
            ],
            standardInputData: payload,
            timeout: 3
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(try Data(contentsOf: capturedInput) == payload)
        #expect(try String(contentsOf: capturedID, encoding: .utf8) == deliveryID)
        #expect(
            try String(contentsOf: capturedArgs, encoding: .utf8)
                == "--socket /tmp/cmux-native-missing.sock hooks codex enqueue prompt-submit"
        )

        let noCLIFallback = runCodexHookProcess(
            executablePath: hookPath,
            arguments: [],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SURFACE_ID": "surface-fallback",
                "CMUX_SOCKET_PATH": "/tmp/cmux-native-missing.sock",
                "CMUX_SOCKET_CAPABILITY": "test-capability",
                "CMUX_CODEX_PID": "4242",
            ],
            standardInputData: payload,
            timeout: 3
        )
        #expect(!noCLIFallback.timedOut, Comment(rawValue: noCLIFallback.stderr))
        #expect(noCLIFallback.status == 0)
        #expect(noCLIFallback.stdout == "{}\n")
    }

    @Test func codexNativeClientTerminatesHungFallbackWithinDeadline() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-native-hung-fallback-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let hooksDirectory = root
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux-hung-fallback", isDirectory: false)
        let leaderPIDFile = root.appendingPathComponent("hung-leader-pid.txt", isDirectory: false)
        let descendantPIDFile = root.appendingPathComponent("hung-descendant-pid.txt", isDirectory: false)
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
        let hookPath = hooksDirectory
            .appendingPathComponent("cmux-codex-hook-stop.sh", isDirectory: false)
            .path
        #expect(codexHookExecutableIsMachO(hookPath))

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s' \"$$\" > \"$CMUX_TEST_LEADER_PID\"",
            "/bin/sh -c 'trap \"\" TERM; printf \"%s\" \"$$\" > \"$CMUX_TEST_DESCENDANT_PID\"; while :; do :; done' &",
            "trap 'exit 143' TERM",
            "while :; do :; done",
        ])
        let started = ContinuousClock().now
        let result = runCodexHookProcess(
            executablePath: hookPath,
            arguments: [],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SURFACE_ID": "surface-hung-fallback",
                "CMUX_SOCKET_PATH": "/tmp/cmux-native-hung-missing.sock",
                "CMUX_SOCKET_CAPABILITY": "test-capability",
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_CODEX_PID": "4242",
                "CMUX_AGENT_HOOK_DELIVERY_ID": "native-hung-fallback",
                "CMUX_TEST_LEADER_PID": leaderPIDFile.path,
                "CMUX_TEST_DESCENDANT_PID": descendantPIDFile.path,
            ],
            standardInputData: Data(repeating: 0xA5, count: 512 * 1024),
            timeout: 3
        )
        let elapsed = started.duration(to: ContinuousClock().now)

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(elapsed < .seconds(2))
        for pidFile in [leaderPIDFile, descendantPIDFile] {
            let rawPID = try String(contentsOf: pidFile, encoding: .utf8)
            let pid = try #require(Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)))
            errno = 0
            #expect(Darwin.kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    @Test func codexPersistentLifecycleHooksAreNativeButFeedHooksStayScripts() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-native-persistent-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(install.status == 0, Comment(rawValue: install.stderr))
        let hooks = try codexHookEntries(in: codexHome)
        let lifecycle = hooks.filter { ["SessionStart", "UserPromptSubmit", "Stop"].contains($0.eventName) }
        let feed = hooks.filter { $0.body.contains("hooks feed --source codex") }
        #expect(lifecycle.count == 3)
        #expect(lifecycle.allSatisfy { codexHookExecutableIsMachO($0.command) })
        #expect(feed.count == 7)
        #expect(feed.allSatisfy { $0.command.hasSuffix(".sh") && !codexHookExecutableIsMachO($0.command) })
    }

    @Test func codexHookUpgradeReplacesPersistentScriptsWithoutSharedPathCollisions() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-native-upgrade-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let hooksDirectory = root.appendingPathComponent(".cmux/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lifecycleEvents = [
            (agentEvent: "SessionStart", subcommand: "session-start"),
            (agentEvent: "UserPromptSubmit", subcommand: "prompt-submit"),
            (agentEvent: "Stop", subcommand: "stop"),
        ]
        var installedHooks: [String: Any] = [:]
        for event in lifecycleEvents {
            let previousPath = hooksDirectory
                .appendingPathComponent("cmux-codex-hook-persistent-\(event.subcommand).sh")
            try makeCodexHookExecutableShellFile(at: previousPath, lines: ["#!/bin/sh", "exit 0"])
            installedHooks[event.agentEvent] = [[
                "hooks": [[
                    "command": previousPath.path,
                    "timeout": 10,
                    "type": "command",
                ]],
            ]]
        }
        let userCommand = "printf 'keep-user-hook'"
        var sessionStart = try #require(installedHooks["SessionStart"] as? [[String: Any]])
        sessionStart.append([
            "hooks": [[
                "command": userCommand,
                "timeout": 10,
                "type": "command",
            ]],
        ])
        installedHooks["SessionStart"] = sessionStart
        let hooksJSON: [String: Any] = ["hooks": installedHooks]
        try JSONSerialization.data(withJSONObject: hooksJSON, options: [.prettyPrinted, .sortedKeys])
            .write(to: codexHome.appendingPathComponent("hooks.json"), options: .atomic)

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let hooks = try codexHookEntries(in: codexHome)
        #expect(hooks.contains { $0.command == userCommand })
        #expect(!hooks.contains { $0.command.contains("cmux-codex-hook-persistent-") })
        for event in lifecycleEvents {
            let entries = hooks.filter { $0.eventName == event.agentEvent }
            let nativeEntries = entries.filter { codexHookExecutableIsMachO($0.command) }
            let historicalSharedPath = hooksDirectory
                .appendingPathComponent("cmux-codex-hook-\(event.subcommand).sh")
            #expect(nativeEntries.count == 1)
            #expect(nativeEntries[0].command != historicalSharedPath.path)
            #expect(nativeEntries[0].command.hasSuffix("cmux-codex-native-hook-\(event.subcommand)"))

            // An older concurrently running cmux still rewrites this historical
            // wrapper path. That must not change the installed native helper.
            try makeCodexHookExecutableShellFile(
                at: historicalSharedPath,
                lines: ["#!/bin/sh", "sleep 30"]
            )
            #expect(codexHookExecutableIsMachO(nativeEntries[0].command))
        }
        let expectedFeedEvents: Set<String> = [
            "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact",
            "PostCompact", "SubagentStart", "SubagentStop",
        ]
        let feedHooks = hooks.filter { $0.body.contains("hooks feed --source codex") }
        let installedFeedEvents = Set(feedHooks.compactMap { hook in
            expectedFeedEvents.first { hook.body.contains("--event \($0)") }
        })
        #expect(feedHooks.count == expectedFeedEvents.count)
        #expect(installedFeedEvents == expectedFeedEvents)
    }

    @Test func codexHookGenerationFallsBackToPortableShellWithoutNativeClient() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-native-unavailable-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var environment = codexHookTestEnvironment(root: root, codexHome: codexHome)
        environment["CMUX_CODEX_HOOK_CLIENT_PATH"] = root.appendingPathComponent("missing-client").path
        let inject = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: environment,
            timeout: 5
        )
        #expect(inject.status == 0, Comment(rawValue: inject.stderr))
        let shellPath = root
            .appendingPathComponent(".cmux/hooks/cmux-codex-hook-session-start.sh", isDirectory: false)
        #expect(!codexHookExecutableIsMachO(shellPath.path))
        let shell = try String(contentsOf: shellPath, encoding: .utf8)
        #expect(shell.hasPrefix("#!/bin/sh\n"))
        #expect(shell.contains("/usr/bin/base64"))
        #expect(shell.contains("/usr/bin/nc"))
        #expect(shell.contains("hooks codex enqueue session-start"))
    }

    @Test func codexPortableHookBoundsSlowCLIFallbackAndPreservesPayload() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-portable-deadline-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let hooksDirectory = root.appendingPathComponent(".cmux/hooks", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux-slow-fallback", isDirectory: false)
        let capturedInput = root.appendingPathComponent("captured-input.bin", isDirectory: false)
        let leaderPIDFile = root.appendingPathComponent("leader.pid", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer {
            if let rawPID = try? String(contentsOf: leaderPIDFile, encoding: .utf8),
               let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Darwin.kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: root)
        }

        var generationEnvironment = codexHookTestEnvironment(root: root, codexHome: codexHome)
        generationEnvironment["CMUX_CODEX_HOOK_CLIENT_PATH"] = root.appendingPathComponent("missing-client").path
        let inject = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: generationEnvironment,
            timeout: 5
        )
        #expect(inject.status == 0, Comment(rawValue: inject.stderr))
        let hookPath = hooksDirectory
            .appendingPathComponent("cmux-codex-portable-hook-session-start.sh", isDirectory: false)
            .path

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s' \"$$\" > \"$CMUX_TEST_LEADER_PID\"",
            "cat > \"$CMUX_TEST_INPUT\"",
            "trap 'exit 143' TERM",
            "while :; do :; done",
        ])
        let payload = Data([0x00, 0x22, 0x5C, 0x7F, 0x80, 0xFF, 0x0A])
        let started = ContinuousClock.now
        let result = runCodexHookProcess(
            executablePath: hookPath,
            arguments: [],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SURFACE_ID": "surface-portable-fallback",
                "CMUX_SOCKET_PATH": "/tmp/cmux-portable-missing.sock",
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_TEST_INPUT": capturedInput.path,
                "CMUX_TEST_LEADER_PID": leaderPIDFile.path,
            ],
            standardInputData: payload,
            timeout: 3
        )
        let elapsed = started.duration(to: .now)

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(elapsed < .seconds(1))
        #expect(try Data(contentsOf: capturedInput) == payload)
        let rawPID = try String(contentsOf: leaderPIDFile, encoding: .utf8)
        let leaderPID = try #require(Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)))
        let leaderGone = waitForCondition(timeout: 1) {
            Darwin.kill(leaderPID, 0) == -1
        }
        #expect(leaderGone)
    }

    @Test func codexLifecycleHooksEnqueueWithoutDetachedProcessTrees() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-inbox-hook-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 10
        )
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let lifecycleHooks = try codexHookEntries(in: codexHome).filter {
            ["SessionStart", "UserPromptSubmit", "Stop"].contains($0.eventName)
        }
        #expect(lifecycleHooks.count == 3)
        #expect(lifecycleHooks.allSatisfy { codexHookExecutableIsMachO($0.command) })
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
        let feedHooks = hooks.filter { $0.body.contains("hooks feed --source codex") }
        #expect(!hooks.map(\.body).contains(previousCommand), "Installer should remove stale synchronous hook")
        #expect(sessionStartHooks.count == 1, "Installer should install one session-start hook")
        #expect(sessionStartHooks.allSatisfy { codexHookExecutableIsMachO($0.command) })
        #expect(sessionStartHooks.allSatisfy { $0.command.hasSuffix("cmux-codex-hook-session-start.sh") })
        #expect(promptHooks.count == 1, "Installer should collapse duplicate prompt hooks")
        #expect(promptHooks.allSatisfy { codexHookExecutableIsMachO($0.command) })
        #expect(promptHooks.allSatisfy { $0.command.hasSuffix("cmux-codex-hook-prompt-submit.sh") })
        #expect(stopHooks.count == 1, "Installer should install one stop hook")
        #expect(stopHooks.allSatisfy { codexHookExecutableIsMachO($0.command) })
        #expect(stopHooks.allSatisfy { $0.command.hasSuffix("cmux-codex-hook-stop.sh") })
        let expectedFeedEvents: Set<String> = [
            "PreToolUse",
            "PermissionRequest",
            "PostToolUse",
            "PreCompact",
            "PostCompact",
            "SubagentStart",
            "SubagentStop",
        ]
        let installedFeedEvents = Set(feedHooks.compactMap { hook in
            expectedFeedEvents.first { hook.body.contains("--event \($0)") }
        })
        #expect(feedHooks.count == expectedFeedEvents.count, "Installer should install every Codex feed hook")
        #expect(installedFeedEvents == expectedFeedEvents)
        #expect(feedHooks.allSatisfy { !$0.body.contains("nohup sh -c") && !$0.body.contains(">/dev/null 2>&1 &") })
    }

    @Test func codexInstalledHookHandsPayloadToInboxCommand() throws {
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
        #expect(waitForFile(capturedArgs, containing: "--socket /tmp/cmux-test.sock hooks codex enqueue prompt-submit", timeout: 1))
        #expect(waitForFile(capturedPID, containing: "4242", timeout: 1))
        #expect(waitForFile(doneFile, containing: "done", timeout: 1))
    }

    @Test func codexGeneratedHookPreservesExactPayloadAndResumeContextOnDirectSocket() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-encoded-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("custom codex home", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("encoded")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let launchCwd = #"/tmp/project \"quoted\"/日本語\\repo"#
        let launchExecutable = #"/tmp/bin/codex \"custom\"\\版本"#
        let payloads = [
            "",
            #"{"session_id":"plain","prompt":"quote: \" and slash: \\"}"#,
            "{\n  \"session_id\": \"unicode-日本語\",\n  \"prompt\": \"line one\\nline two\"\n}\n",
            #"{},"payload_b64":"YXR0YWNr","environment":{"CMUX_SOCKET_PATH":"/tmp/injected"}"#,
            "not-json: \"quoted\" \\ path 日本語\n",
            String(repeating: "x", count: 256 * 1024),
        ]
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
            connectionLimit: payloads.count
        )
        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(install.status == 0, Comment(rawValue: install.stderr))
        let command = try #require(
            codexHookEntries(in: codexHome).first { $0.eventName == "UserPromptSubmit" }?.command
        )

        for (index, payload) in payloads.enumerated() {
            let deliveryID = "encoded-payload-\(index)"
            let run = runCodexHookProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", command],
                environment: [
                    "HOME": root.path,
                    "CODEX_HOME": codexHome.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "PWD": launchCwd,
                    "TMPDIR": root.path,
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_SOCKET_CAPABILITY": "test-capability",
                    "CMUX_WORKSPACE_ID": workspaceId,
                    "CMUX_SURFACE_ID": surfaceId,
                    "CMUX_CODEX_PID": "4242",
                    "CMUX_AGENT_HOOK_DELIVERY_ID": deliveryID,
                    "CMUX_AGENT_LAUNCH_CWD": launchCwd,
                    "CMUX_AGENT_LAUNCH_EXECUTABLE": launchExecutable,
                    "CMUX_AGENT_LAUNCH_KIND": "codex",
                    "CMUX_AGENT_LAUNCH_ARGV_B64": Data("codex\0resume\0session\0".utf8).base64EncodedString(),
                    "CMUX_BUNDLED_CLI_PATH": cliPath,
                ],
                standardInput: payload,
                timeout: 5
            )
            #expect(!run.timedOut, Comment(rawValue: run.stderr))
            #expect(run.status == 0, Comment(rawValue: run.stderr))
            #expect(run.stdout == "{}\n")
            #expect(waitForCondition(timeout: 2) {
                commands.snapshot().compactMap(codexHookJSONObject).filter {
                    $0["method"] as? String == "agent.hook.enqueue"
                }.count == index + 1
            })

            let request = try #require(commands.snapshot().compactMap(codexHookJSONObject).last)
            let params = try #require(request["params"] as? [String: Any])
            #expect(params["delivery_id"] as? String == deliveryID)
            let payloadBase64 = try #require(params["payload_b64"] as? String)
            let deliveredPayload = try #require(Data(base64Encoded: payloadBase64))
            #expect(deliveredPayload == Data(payload.utf8))
            let environmentBase64 = try #require(params["environment_b64"] as? String)
            let deliveredEnvironment = try #require(decodeNULSeparatedEnvironment(environmentBase64))
            #expect(deliveredEnvironment["CODEX_HOME"] == codexHome.path)
            #expect(deliveredEnvironment["CMUX_AGENT_LAUNCH_CWD"] == launchCwd)
            #expect(deliveredEnvironment["CMUX_AGENT_LAUNCH_EXECUTABLE"] == launchExecutable)
            #expect(deliveredEnvironment["CMUX_SOCKET_PATH"] == socketPath)
        }
    }

    @Test func codexGeneratedHookUsesProcessLightNativeEncoding() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-fast-lane-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("fast")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let surfaceId = "22222222-2222-2222-2222-222222222222"
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
            connectionLimit: 1
        )
        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(install.status == 0, Comment(rawValue: install.stderr))
        let command = try #require(
            codexHookEntries(in: codexHome).first { $0.eventName == "SessionStart" }?.command
        )
        let payload = #"{"session_id":"fast-lane","cwd":"/tmp/project-safe","hook_event_name":"SessionStart"}"#
        let result = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            environment: [
                "HOME": root.path,
                "CODEX_HOME": codexHome.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": "/tmp/project-safe",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_SOCKET_CAPABILITY": "test-capability",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_CODEX_PID": "4242",
                "CMUX_AGENT_HOOK_DELIVERY_ID": "fast-lane-event",
                "CMUX_AGENT_LAUNCH_CWD": "/tmp/project-safe",
                "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/codex",
                "CMUX_AGENT_LAUNCH_KIND": "codex",
                "CMUX_AGENT_LAUNCH_ARGV_B64": Data("codex\0".utf8).base64EncodedString(),
                "CMUX_BUNDLED_CLI_PATH": cliPath,
            ],
            standardInput: payload,
            timeout: 3
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")

        let request = try #require(commands.snapshot().compactMap(codexHookJSONObject).last)
        let params = try #require(request["params"] as? [String: Any])
        let payloadBase64 = try #require(params["payload_b64"] as? String)
        #expect(Data(base64Encoded: payloadBase64) == Data(payload.utf8))
        #expect(params["payload_json"] == nil)
        let environmentBase64 = try #require(params["environment_b64"] as? String)
        let environment = try #require(decodeNULSeparatedEnvironment(environmentBase64))
        #expect(environment["CMUX_AGENT_LAUNCH_CWD"] == "/tmp/project-safe")
        #expect(environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] == "/usr/local/bin/codex")
        #expect(params["environment"] == nil)
    }

    @Test func codexQueueFallbackAcceptsEveryWrapperEvent() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-fallback-events-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("fallback")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
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
            connectionLimit: 6
        )

        let subcommands = [
            "session-start", "prompt-submit", "stop",
            "pre-tool-use", "post-tool-use", "notification",
        ]
        let payloads = [Data([0x00, 0xFF, 0x0A, 0x22, 0x5C, 0x7F])]
            + subcommands.dropFirst().map { Data("payload-\($0)".utf8) }
        for (index, subcommand) in subcommands.enumerated() {
            let result = runCodexHookProcess(
                executablePath: cliPath,
                arguments: ["--socket", socketPath, "hooks", "codex", "enqueue", subcommand],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_SURFACE_ID": surfaceId,
                    "CMUX_AGENT_HOOK_DELIVERY_ID": "fallback-event-\(index)",
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                ],
                standardInputData: payloads[index],
                timeout: 3
            )
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
        }

        let queuedParams = commands.snapshot().compactMap(codexHookJSONObject).compactMap { request -> [String: Any]? in
            guard request["method"] as? String == "agent.hook.enqueue" else { return nil }
            return request["params"] as? [String: Any]
        }
        #expect(queuedParams.compactMap { $0["subcommand"] as? String } == subcommands)
        for (index, params) in queuedParams.enumerated() {
            let payloadBase64 = try #require(params["payload_b64"] as? String)
            #expect(Data(base64Encoded: payloadBase64) == payloads[index])
            #expect(params["payload"] == nil)
        }
    }

    @Test func codexResumeUsesGeneratedQueuedSessionStartBeforeExec() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-wrapper-resume-\(UUID().uuidString)", isDirectory: true)
        let hooksDirectory = root
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux", isDirectory: false)
        let fakeCodex = root.appendingPathComponent("codex-real", isDirectory: false)
        let resumeHook = hooksDirectory.appendingPathComponent("cmux-codex-hook-session-start.sh", isDirectory: false)
        let capturedPayload = root.appendingPathComponent("resume-payload.json", isDirectory: false)
        let capturedDeliveryID = root.appendingPathComponent("resume-delivery-id.txt", isDirectory: false)
        let capturedCodexArgs = root.appendingPathComponent("codex-args.txt", isDirectory: false)
        let socketPath = makeCodexHookSocketPath("wrapper")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let sessionID = "12345678-1234-1234-1234-123456789abc"
        let wrapper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bin/cmux-codex-wrapper", isDirectory: false)
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "case \"$*\" in",
            "  *ping*) exit 0 ;;",
            "  *\"hooks codex inject-args\"*) printf '%s\\0' --enable hooks; exit 0 ;;",
            "esac",
            "exit 1",
        ])
        try makeCodexHookExecutableShellFile(at: resumeHook, lines: [
            "#!/bin/sh",
            "cat > \"$CMUX_TEST_RESUME_PAYLOAD\"",
            "printf '%s' \"$CMUX_AGENT_HOOK_DELIVERY_ID\" > \"$CMUX_TEST_RESUME_DELIVERY_ID\"",
        ])
        try makeCodexHookExecutableShellFile(at: fakeCodex, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$@\" > \"$CMUX_TEST_CODEX_ARGS\"",
        ])

        let result = runCodexHookProcess(
            executablePath: wrapper.path,
            arguments: ["resume", sessionID],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_CUSTOM_CODEX_PATH": fakeCodex.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_SURFACE_ID": "surface-wrapper",
                "CMUX_WORKSPACE_ID": "workspace-wrapper",
                "CMUX_TEST_RESUME_PAYLOAD": capturedPayload.path,
                "CMUX_TEST_RESUME_DELIVERY_ID": capturedDeliveryID.path,
                "CMUX_TEST_CODEX_ARGS": capturedCodexArgs.path,
            ],
            timeout: 5
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: capturedPayload, encoding: .utf8) == #"{"session_id":"12345678-1234-1234-1234-123456789abc"}"#)
        let deliveryID = try String(contentsOf: capturedDeliveryID, encoding: .utf8)
        #expect(deliveryID.hasPrefix("codex-resume-"))
        let codexArgs = try String(contentsOf: capturedCodexArgs, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(codexArgs == ["--enable", "hooks", "resume", sessionID])
    }

    @Test func codexInstalledStopHookHandsPayloadToInboxCommand() throws {
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
        #expect(waitForFile(capturedArgs, containing: "--socket /tmp/cmux-test.sock hooks codex enqueue stop", timeout: 1))
        #expect(waitForFile(capturedPID, containing: "4242", timeout: 1))
        #expect(waitForFile(doneFile, containing: "done", timeout: 3))
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
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"old"}"#,
            timeout: 3
        )
        #expect(oldPrompt.status == 0, Comment(rawValue: oldPrompt.stderr))
        #expect(oldPrompt.stdout == "{}\n")
        #expect(waitForCondition(timeout: 2) {
            commands.snapshot().contains { $0.hasPrefix("set_status codex Running ") }
        })

        let currentPrompt = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"current"}"#,
            timeout: 3
        )
        #expect(currentPrompt.status == 0, Comment(rawValue: currentPrompt.stderr))
        #expect(currentPrompt.stdout == "{}\n")
        #expect(waitForCondition(timeout: 2) {
            let snapshot = commands.snapshot()
            return snapshot.contains { $0.hasPrefix("clear_notifications ") }
                && snapshot.contains { $0.hasPrefix("set_status codex Running ") }
        })

        let staleStopStart = commands.snapshot().count
        let staleStop = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "hooks", "codex", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(root.path)","hook_event_name":"Stop","last_assistant_message":"old done"}"#,
            timeout: 3
        )
        #expect(staleStop.status == 0, Comment(rawValue: staleStop.stderr))
        #expect(staleStop.stdout == "{}\n")
        #expect(waitForCondition(timeout: 2) {
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
        #expect(!sentCommands.contains { $0.hasPrefix("set_agent_lifecycle codex unknown ") })
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
        #expect(sentCommands.contains { $0.hasPrefix("set_agent_lifecycle codex unknown ") })
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
        #expect(!sentCommands.contains { $0.hasPrefix("set_agent_lifecycle codex unknown ") })
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

    private func decodeNULSeparatedEnvironment(_ encoded: String) -> [String: String]? {
        guard let data = Data(base64Encoded: encoded) else { return nil }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.last?.isEmpty == true, fields.count.isMultiple(of: 2) == false else { return nil }
        var environment: [String: String] = [:]
        var index = 0
        while index + 1 < fields.count - 1 {
            guard let key = String(data: fields[index], encoding: .utf8),
                  let value = String(data: fields[index + 1], encoding: .utf8) else {
                return nil
            }
            environment[key] = value
            index += 2
        }
        return environment
    }
}
