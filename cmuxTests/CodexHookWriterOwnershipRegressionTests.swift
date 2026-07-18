import Darwin
import Foundation
import XCTest

final class CodexHookWriterOwnershipRegressionTests: XCTestCase {
    func testWrapperClassifiesCurrentGlobalOptionWidthsBeforeUtilitiesAndSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-wrapper-widths-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux", isDirectory: false)
        let fakeCodex = root.appendingPathComponent("codex-real", isDirectory: false)
        let socketPath = makeCodexHookSocketPath("widths")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"$TEST_CLI_CAPTURE\"",
            "exit 0",
        ])
        try makeCodexHookExecutableShellFile(at: fakeCodex, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" > \"$TEST_CODEX_CAPTURE\"",
        ])
        let wrapper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bin/cmux-codex-wrapper", isDirectory: false)

        let utilityCases = [
            ["--remote-auth-token-env", "CODEX_TOKEN", "plugin", "list"],
            ["--local-provider", "ollama", "plugin", "list"],
            ["--add-dir", "/tmp/source tree", "plugin", "list"],
            ["initial prompt", "--help"],
            ["-i", "/tmp/a.png", "/tmp/b.png", "--help"],
            ["resume", "019dad34-d218-7943-b81a-eddac5c87951", "--version"],
        ]
        let sessionOrRootCases = [
            ["--add-dir", "/tmp/source tree", "fork", "019dad34-d218-7943-b81a-eddac5c87951"],
            ["--local-provider", "ollama", "resume", "019dad34-d218-7943-b81a-eddac5c87951"],
            ["--remote-auth-token-env", "CODEX_TOKEN", "exec", "echo", "ok"],
            // Codex 0.144.3 parses --image/-i as <FILE>..., so every following
            // bare token belongs to the root invocation. `plugin` and `exec`
            // here are image values, not subcommands, and the wrapper must keep
            // treating the resulting root launch as a session.
            ["--image", "/tmp/a.png", "plugin", "list"],
            ["-i", "/tmp/a.png", "plugin", "list"],
            ["--image", "/tmp/a.png", "/tmp/b.png", "plugin", "list"],
            ["--image", "/tmp/a.png", "/tmp/b.png", "exec", "echo", "ok"],
        ]

        for (index, arguments) in (utilityCases + sessionOrRootCases).enumerated() {
            let cliCapture = root.appendingPathComponent("cli-\(index).txt", isDirectory: false)
            let codexCapture = root.appendingPathComponent("codex-\(index).txt", isDirectory: false)
            let result = runCodexHookProcess(
                executablePath: wrapper.path,
                arguments: arguments,
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "CMUX_SURFACE_ID": "surface-widths",
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                    "CMUX_CUSTOM_CODEX_PATH": fakeCodex.path,
                    "TEST_CLI_CAPTURE": cliCapture.path,
                    "TEST_CODEX_CAPTURE": codexCapture.path,
                ],
                timeout: 3
            )
            XCTAssertFalse(result.timedOut, result.stderr)
            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertEqual(
                try String(contentsOf: codexCapture, encoding: .utf8)
                    .trimmingCharacters(in: .newlines),
                arguments.joined(separator: " ")
            )
            let cliInvocations = (try? String(contentsOf: cliCapture, encoding: .utf8)) ?? ""
            if index < utilityCases.count {
                XCTAssertFalse(cliInvocations.contains("hooks codex install --yes"), "\(arguments): \(cliInvocations)")
            } else {
                XCTAssertTrue(
                    waitForFile(cliCapture, containing: "hooks codex install --yes", timeout: 1),
                    "\(arguments): \(cliInvocations)"
                )
            }
        }
    }

    func testWrapperRoutesResumeAndForkThroughCustomCodexWithHookOwnership() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux codex custom path \(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux test cli", isDirectory: false)
        let fakeCodex = root.appendingPathComponent("Custom Codex Builds/codex", isDirectory: false)
        let cliCapture = root.appendingPathComponent("cli-invocations.txt", isDirectory: false)
        let socketPath = makeCodexHookSocketPath("replay")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        try FileManager.default.createDirectory(
            at: fakeCodex.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"$TEST_CLI_CAPTURE\"",
            "exit 0",
        ])
        try makeCodexHookExecutableShellFile(at: fakeCodex, lines: [
            "#!/bin/sh",
            "printf 'owner=%s\\nlaunch=%s\\nargs=%s\\n' \"${CMUX_CODEX_WRAPPER_HOOK_OWNER:-unset}\" \"${CMUX_AGENT_LAUNCH_EXECUTABLE:-unset}\" \"$*\" > \"$TEST_CAPTURE\"",
        ])

        let wrapper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bin/cmux-codex-wrapper", isDirectory: false)
        let sessionID = "019dad34-d218-7943-b81a-eddac5c87951"
        for command in ["resume", "fork"] {
            let capture = root.appendingPathComponent("\(command)-capture.txt", isDirectory: false)
            let result = runCodexHookProcess(
                executablePath: wrapper.path,
                arguments: [command, sessionID, "--model", "gpt-5.4"],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "CMUX_SURFACE_ID": "surface-replay",
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                    "CMUX_CUSTOM_CODEX_PATH": fakeCodex.path,
                    "TEST_CAPTURE": capture.path,
                    "TEST_CLI_CAPTURE": cliCapture.path,
                ],
                timeout: 3
            )

            XCTAssertFalse(result.timedOut, result.stderr)
            XCTAssertEqual(result.status, 0, result.stderr)
            let captured = try String(contentsOf: capture, encoding: .utf8)
            XCTAssertTrue(captured.contains("owner=1"), "\(command): \(captured)")
            XCTAssertTrue(captured.contains("launch=\(fakeCodex.path)"), "\(command): \(captured)")
            XCTAssertTrue(
                captured.contains("args=\(command) \(sessionID) --model gpt-5.4"),
                "\(command): \(captured)"
            )
        }

        XCTAssertTrue(waitForFile(cliCapture, containing: "hooks codex install --yes", timeout: 1))
        XCTAssertTrue(waitForFile(cliCapture, containing: "hooks codex session-start", timeout: 1))
    }

    func testWrapperFallsBackSafelyFromStaleAndNonExecutableCustomCodexPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-custom-fallback-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let fallbackCodex = bin.appendingPathComponent("codex", isDirectory: false)
        let nonExecutableCodex = root.appendingPathComponent("not executable/codex", isDirectory: false)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: nonExecutableCodex.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try makeCodexHookExecutableShellFile(at: fallbackCodex, lines: [
            "#!/bin/sh",
            "printf 'fallback=%s\\nargs=%s\\n' \"$0\" \"$*\" > \"$TEST_CAPTURE\"",
        ])
        try "#!/bin/sh\nexit 99\n".write(
            to: nonExecutableCodex,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: nonExecutableCodex.path
        )

        let wrapper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bin/cmux-codex-wrapper", isDirectory: false)
        let invalidPaths = [
            root.appendingPathComponent("moved Codex/codex", isDirectory: false).path,
            nonExecutableCodex.path,
        ]
        for (index, customPath) in invalidPaths.enumerated() {
            let capture = root.appendingPathComponent("fallback-\(index).txt", isDirectory: false)
            let result = runCodexHookProcess(
                executablePath: wrapper.path,
                arguments: ["review", "--help"],
                environment: [
                    "HOME": root.path,
                    "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
                    "CMUX_CUSTOM_CODEX_PATH": customPath,
                    "TEST_CAPTURE": capture.path,
                ],
                timeout: 3
            )
            XCTAssertFalse(result.timedOut, result.stderr)
            XCTAssertEqual(result.status, 0, result.stderr)
            let captured = try String(contentsOf: capture, encoding: .utf8)
            XCTAssertTrue(captured.contains("fallback=\(fallbackCodex.path)"), captured)
            XCTAssertTrue(captured.contains("args=review --help"), captured)
        }
    }

    func testExplicitDisableWinsOverInheritedWrapperOwnership() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-opt-out-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux", isDirectory: false)
        let fakeCodex = root.appendingPathComponent("codex-real", isDirectory: false)
        let capturedEnvironment = root.appendingPathComponent("codex-environment.txt", isDirectory: false)
        let capturedCLIInvocations = root.appendingPathComponent("cmux-invocations.txt", isDirectory: false)
        let socketPath = makeCodexHookSocketPath("opt-out")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"$TEST_CLI_CAPTURE\"",
        ])
        try makeCodexHookExecutableShellFile(at: fakeCodex, lines: [
            "#!/bin/sh",
            "printf 'disabled=%s\\nowner=%s\\nargs=%s\\n' \"${CMUX_CODEX_HOOKS_DISABLED:-unset}\" \"${CMUX_CODEX_WRAPPER_HOOK_OWNER:-unset}\" \"$*\" > \"$TEST_CAPTURE\"",
        ])

        let wrapper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bin/cmux-codex-wrapper", isDirectory: false)
        let result = runCodexHookProcess(
            executablePath: wrapper.path,
            arguments: [],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SURFACE_ID": "surface-opt-out",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_CUSTOM_CODEX_PATH": fakeCodex.path,
                "CMUX_CODEX_HOOKS_DISABLED": "1",
                "CMUX_CODEX_WRAPPER_HOOK_OWNER": "1",
                "TEST_CAPTURE": capturedEnvironment.path,
                "TEST_CLI_CAPTURE": capturedCLIInvocations.path,
            ],
            timeout: 3
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let captured = try String(contentsOf: capturedEnvironment, encoding: .utf8)
        XCTAssertTrue(captured.contains("disabled=unset"))
        XCTAssertTrue(captured.contains("owner=unset"))
        XCTAssertTrue(captured.contains("args=\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: capturedCLIInvocations.path))
    }

    func testWrapperPrefersTrustedPersistentHooksOverUntrustedSessionFlags() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-owner-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux", isDirectory: false)
        let fakeCodex = root.appendingPathComponent("codex-real", isDirectory: false)
        let capturedEnvironment = root.appendingPathComponent("codex-environment.txt", isDirectory: false)
        let capturedCLIInvocations = root.appendingPathComponent("cmux-invocations.txt", isDirectory: false)
        let socketPath = makeCodexHookSocketPath("owner")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"$CMUX_TEST_CLI_CAPTURE\"",
            "case \" $* \" in",
            "  *\" hooks codex install --yes \"*) exit 0 ;;",
            "  *\" hooks codex inject-args \"*) printf '%s\\0' --yolo ;;",
            "esac",
            "exit 0",
        ])
        try makeCodexHookExecutableShellFile(at: fakeCodex, lines: [
            "#!/bin/sh",
            "printf 'disabled=%s\\nowner=%s\\nargs=%s\\n' \"${CMUX_CODEX_HOOKS_DISABLED:-unset}\" \"${CMUX_CODEX_WRAPPER_HOOK_OWNER:-unset}\" \"$*\" > \"$CMUX_TEST_CAPTURE\"",
        ])

        let wrapper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bin/cmux-codex-wrapper", isDirectory: false)
        let result = runCodexHookProcess(
            executablePath: wrapper.path,
            arguments: [],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SURFACE_ID": "surface-owner",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_CUSTOM_CODEX_PATH": fakeCodex.path,
                "CMUX_TEST_CAPTURE": capturedEnvironment.path,
                "CMUX_TEST_CLI_CAPTURE": capturedCLIInvocations.path,
            ],
            timeout: 3
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let captured = try String(contentsOf: capturedEnvironment, encoding: .utf8)
        XCTAssertTrue(captured.contains("disabled=0"))
        XCTAssertTrue(captured.contains("owner=1"))
        XCTAssertTrue(captured.contains("args=\n"))
        let invocations = try String(contentsOf: capturedCLIInvocations, encoding: .utf8)
        XCTAssertTrue(invocations.contains("hooks codex install --yes"))
        XCTAssertFalse(invocations.contains("hooks codex inject-args"))
    }

    func testInjectedHooksRequireWrapperOwnershipWhilePersistentHooksRespectDisable() throws {
        let cliPath = try bundledCLIPath()
        let result = runCodexInjectArgsProcess(executablePath: cliPath)
        XCTAssertEqual(result.status, 0, result.stderr)

        let arguments = result.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        let hookConfigurations = arguments.filter { $0.hasPrefix("hooks.") }
        XCTAssertFalse(hookConfigurations.isEmpty)
        for configuration in hookConfigurations {
            let marker = "command='''"
            let commandStart = try XCTUnwrap(configuration.range(of: marker)?.upperBound)
            let commandEnd = try XCTUnwrap(configuration.range(of: "'''", range: commandStart..<configuration.endIndex)?.lowerBound)
            let scriptPath = String(configuration[commandStart..<commandEnd])
            let body = try String(contentsOfFile: scriptPath, encoding: .utf8)
            XCTAssertTrue(body.contains("CMUX_CODEX_WRAPPER_HOOK_OWNER"))
            XCTAssertTrue(body.contains("= \"1\""))
        }
    }

    func testPersistentHooksBindToNativeCodexProcessBeforeWrapperFallback() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-native-pid-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        XCTAssertEqual(install.status, 0, install.stderr)
        let sessionStart = try XCTUnwrap(
            codexHookEntries(in: codexHome).first { $0.eventName == "SessionStart" }
        )
        XCTAssertTrue(sessionStart.body.contains(#"agent_pid="${PPID:-${CMUX_CODEX_PID:-}}""#))
    }

    func testPersistentHooksDoNotPinOneCmuxInstanceIntoSharedCodexConfig() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-shared-config-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let firstCLI = root.appendingPathComponent("cmux-first", isDirectory: false)
        let secondCLI = root.appendingPathComponent("cmux-second", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: cliPath), to: firstCLI)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: cliPath), to: secondCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: firstCLI.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secondCLI.path)
        defer { try? FileManager.default.removeItem(at: root) }

        func install(cli: URL, socket: String) throws -> [InstalledHookEntry] {
            var environment = codexHookTestEnvironment(root: root, codexHome: codexHome)
            environment["CMUX_BUNDLED_CLI_PATH"] = cli.path
            environment["CMUX_SOCKET_PATH"] = socket
            let result = runCodexHookProcess(
                executablePath: cliPath,
                arguments: ["hooks", "codex", "install", "--yes"],
                environment: environment,
                timeout: 10
            )
            XCTAssertEqual(result.status, 0, result.stderr)
            return try codexHookEntries(in: codexHome)
        }

        let firstHooks = try install(cli: firstCLI, socket: "/tmp/cmux-debug-first.sock")
        let secondHooks = try install(cli: secondCLI, socket: "/tmp/cmux-debug-second.sock")
        XCTAssertEqual(firstHooks.map(\.command).sorted(), secondHooks.map(\.command).sorted())
        for hook in secondHooks where hook.body.contains("hooks codex") {
            XCTAssertTrue(hook.body.contains("CMUX_CODEX_HOOK_CMUX_BIN"))
            XCTAssertTrue(hook.body.contains("CMUX_SOCKET_PATH"))
            XCTAssertFalse(hook.body.contains(firstCLI.path))
            XCTAssertFalse(hook.body.contains(secondCLI.path))
            XCTAssertFalse(hook.body.contains("/tmp/cmux-debug-first.sock"))
            XCTAssertFalse(hook.body.contains("/tmp/cmux-debug-second.sock"))
        }
    }

    func testHookScriptsAreImmutableAcrossConcurrentCmuxVersions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-content-address-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = runCodexInjectArgsProcess(
            executablePath: try bundledCLIPath(),
            homeDirectory: root.path
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        let arguments = result.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        let sessionStart = try XCTUnwrap(arguments.first { $0.hasPrefix("hooks.SessionStart=") })
        let marker = "command='''"
        let commandStart = try XCTUnwrap(sessionStart.range(of: marker)?.upperBound)
        let commandEnd = try XCTUnwrap(sessionStart.range(
            of: "'''",
            range: commandStart..<sessionStart.endIndex
        )?.lowerBound)
        let currentPath = String(sessionStart[commandStart..<commandEnd])
        let currentBody = try String(contentsOfFile: currentPath, encoding: .utf8)
        let legacyPath = URL(fileURLWithPath: currentPath)
            .deletingLastPathComponent()
            .appendingPathComponent("cmux-codex-hook-session-start.sh")
            .path

        XCTAssertNotEqual(currentPath, legacyPath)
        try "#!/bin/sh\nolder-path-fallback-body\n".write(
            toFile: legacyPath,
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(try String(contentsOfFile: currentPath, encoding: .utf8), currentBody)
    }

    func testSetupPrunesLegacyProjectDispatcherButPreservesUserHook() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-legacy-owner-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyCommand = "'\(root.path)/project/.codex/hooks/cmux-codex-fire-and-forget.sh' prompt-submit"
        let userCommand = "\(root.path)/user-prompt-hook.sh"
        let config: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    ["hooks": [["type": "command", "command": legacyCommand, "timeout": 1]]],
                    ["hooks": [["type": "command", "command": userCommand, "timeout": 5]]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            .write(to: codexHome.appendingPathComponent("hooks.json"), options: .atomic)

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        XCTAssertEqual(install.status, 0, install.stderr)

        let promptHooks = try codexHookEntries(in: codexHome)
            .filter { $0.eventName == "UserPromptSubmit" }
        XCTAssertFalse(promptHooks.contains { $0.command == legacyCommand })
        XCTAssertTrue(promptHooks.contains { $0.command == userCommand })
        XCTAssertEqual(promptHooks.filter { $0.body.contains("hooks codex prompt-submit") }.count, 1)
    }

    func testSetupReplacesOlderContentAddressedAndInlineDispatchers() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-old-script-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let hookDirectory = root.appendingPathComponent(".cmux/hooks", isDirectory: true)
        let oldScript = hookDirectory
            .appendingPathComponent("cmux-codex-hook-persistent-session-start-deadbeef.sh")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hookDirectory, withIntermediateDirectories: true)
        try makeCodexHookExecutableShellFile(at: oldScript, lines: ["#!/bin/sh", "exit 0"])
        defer { try? FileManager.default.removeItem(at: root) }
        let oldInlineDispatcher = #"cmux_cli="${CMUX_BUNDLED_CLI_PATH:-}"; "$cmux_cli" hooks codex session-start"#
        let hooksJSON: [String: Any] = [
            "hooks": ["SessionStart": [
                ["hooks": [["command": oldScript.path, "timeout": 5, "type": "command"]]],
                ["hooks": [["command": oldInlineDispatcher, "timeout": 5, "type": "command"]]],
                ["hooks": [["command": "user-session-hook", "timeout": 5, "type": "command"]]],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: hooksJSON, options: [.prettyPrinted, .sortedKeys])
            .write(to: codexHome.appendingPathComponent("hooks.json"), options: .atomic)

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 10
        )
        XCTAssertEqual(install.status, 0, install.stderr)
        let hooks = try codexHookEntries(in: codexHome).filter { $0.eventName == "SessionStart" }
        XCTAssertFalse(hooks.contains { $0.command == oldScript.path })
        XCTAssertFalse(hooks.contains { $0.command == oldInlineDispatcher })
        XCTAssertTrue(hooks.contains { $0.command == "user-session-hook" })
        XCTAssertEqual(hooks.filter { $0.body.contains("hooks codex session-start") }.count, 1)
    }

    private func runCodexInjectArgsProcess(
        executablePath: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["hooks", "codex", "inject-args"]
        process.environment = [
            "HOME": homeDirectory,
            "CFFIXED_USER_HOME": homeDirectory,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, Data(), String(describing: error))
        }
        return (
            process.terminationStatus,
            stdout.fileHandleForReading.readDataToEndOfFile(),
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
    }
}
