import Darwin
import Foundation
import Testing

@Suite
struct CodexHookWriterOwnershipRegressionTests {
    struct WrapperClassificationCase: Sendable, CustomTestStringConvertible {
        let arguments: [String]
        let expectsHookInstallation: Bool

        var testDescription: String {
            arguments.joined(separator: " ")
        }
    }

    struct WrapperReplayCase: Sendable, CustomTestStringConvertible {
        let command: String
        let expectsSyntheticSessionStart: Bool

        var testDescription: String { command }
    }

    enum InvalidCustomCodexCase: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case stale
        case nonExecutable

        var testDescription: String { rawValue }
    }

    static let wrapperClassificationCases: [WrapperClassificationCase] = [
        WrapperClassificationCase(
            arguments: ["--remote-auth-token-env", "CODEX_TOKEN", "plugin", "list"],
            expectsHookInstallation: false
        ),
        WrapperClassificationCase(
            arguments: ["--local-provider", "ollama", "plugin", "list"],
            expectsHookInstallation: false
        ),
        WrapperClassificationCase(
            arguments: ["--add-dir", "/tmp/source tree", "plugin", "list"],
            expectsHookInstallation: false
        ),
        WrapperClassificationCase(
            arguments: ["--image=/tmp/a.png", "plugin", "list"],
            expectsHookInstallation: false
        ),
        WrapperClassificationCase(arguments: ["initial prompt", "--help"], expectsHookInstallation: false),
        WrapperClassificationCase(
            arguments: ["-i", "/tmp/a.png", "/tmp/b.png", "--help"],
            expectsHookInstallation: false
        ),
        WrapperClassificationCase(
            arguments: ["resume", "019dad34-d218-7943-b81a-eddac5c87951", "--version"],
            expectsHookInstallation: false
        ),
        WrapperClassificationCase(
            arguments: ["--add-dir", "/tmp/source tree", "fork", "019dad34-d218-7943-b81a-eddac5c87951"],
            expectsHookInstallation: true
        ),
        WrapperClassificationCase(
            arguments: ["--local-provider", "ollama", "resume", "019dad34-d218-7943-b81a-eddac5c87951"],
            expectsHookInstallation: true
        ),
        WrapperClassificationCase(
            arguments: ["--remote-auth-token-env", "CODEX_TOKEN", "exec", "echo", "ok"],
            expectsHookInstallation: true
        ),
        WrapperClassificationCase(
            arguments: ["--image=/tmp/a.png", "resume", "019dad34-d218-7943-b81a-eddac5c87951"],
            expectsHookInstallation: true
        ),
        // Codex 0.144.3 parses --image/-i as <FILE>..., so every following
        // bare token belongs to the root invocation. `plugin` and `exec`
        // here are image values, not subcommands, and the wrapper must keep
        // treating the resulting root launch as a session.
        WrapperClassificationCase(
            arguments: ["--image", "/tmp/a.png", "plugin", "list"],
            expectsHookInstallation: true
        ),
        WrapperClassificationCase(
            arguments: ["-i", "/tmp/a.png", "plugin", "list"],
            expectsHookInstallation: true
        ),
        WrapperClassificationCase(
            arguments: ["--image", "/tmp/a.png", "/tmp/b.png", "plugin", "list"],
            expectsHookInstallation: true
        ),
        WrapperClassificationCase(
            arguments: ["--image", "/tmp/a.png", "/tmp/b.png", "exec", "echo", "ok"],
            expectsHookInstallation: true
        ),
    ]

    static let wrapperReplayCases: [WrapperReplayCase] = [
        WrapperReplayCase(command: "resume", expectsSyntheticSessionStart: true),
        WrapperReplayCase(command: "fork", expectsSyntheticSessionStart: false),
    ]

    @Test(arguments: wrapperClassificationCases)
    func `Wrapper classifies current global option widths before utilities and sessions`(
        classification: WrapperClassificationCase
    ) throws {
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
        let cliCapture = root.appendingPathComponent("cli.txt", isDirectory: false)
        let codexCapture = root.appendingPathComponent("codex.txt", isDirectory: false)
        let result = runCodexHookProcess(
            executablePath: wrapper.path,
            arguments: classification.arguments,
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
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(
            try String(contentsOf: codexCapture, encoding: .utf8)
                .trimmingCharacters(in: .newlines) == classification.arguments.joined(separator: " ")
        )
        if classification.expectsHookInstallation {
            #expect(
                waitForFile(cliCapture, containing: "hooks codex install --yes", timeout: 1),
                "\(classification.arguments)"
            )
        } else {
            Thread.sleep(forTimeInterval: 0.1)
            let cliInvocations = (try? String(contentsOf: cliCapture, encoding: .utf8)) ?? ""
            #expect(
                !cliInvocations.contains("hooks codex install --yes"),
                "\(classification.arguments): \(cliInvocations)"
            )
        }
    }

    @Test(arguments: wrapperReplayCases)
    func `Wrapper routes resume and fork through custom Codex with hook ownership`(
        replay: WrapperReplayCase
    ) throws {
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
        let capture = root.appendingPathComponent("\(replay.command)-capture.txt", isDirectory: false)
        let result = runCodexHookProcess(
            executablePath: wrapper.path,
            arguments: [replay.command, sessionID, "--model", "gpt-5.4"],
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

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let captured = try String(contentsOf: capture, encoding: .utf8)
        #expect(captured.contains("owner=1"), "\(replay.command): \(captured)")
        #expect(captured.contains("launch=\(fakeCodex.path)"), "\(replay.command): \(captured)")
        #expect(
            captured.contains("args=\(replay.command) \(sessionID) --model gpt-5.4"),
            "\(replay.command): \(captured)"
        )
        #expect(waitForFile(cliCapture, containing: "hooks codex install --yes", timeout: 1))
        if replay.expectsSyntheticSessionStart {
            #expect(waitForFile(cliCapture, containing: "hooks codex session-start", timeout: 1))
        } else {
            Thread.sleep(forTimeInterval: 0.1)
            let cliInvocations = try String(contentsOf: cliCapture, encoding: .utf8)
            #expect(!cliInvocations.contains("hooks codex session-start"), Comment(rawValue: cliInvocations))
        }
    }

    @Test(arguments: InvalidCustomCodexCase.allCases)
    func `Wrapper falls back safely from invalid custom Codex paths`(
        invalidCase: InvalidCustomCodexCase
    ) throws {
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
        let customPath = switch invalidCase {
        case .stale:
            root.appendingPathComponent("moved Codex/codex", isDirectory: false).path
        case .nonExecutable:
            nonExecutableCodex.path
        }
        let capture = root.appendingPathComponent("fallback.txt", isDirectory: false)
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
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let captured = try String(contentsOf: capture, encoding: .utf8)
        #expect(captured.contains("fallback=\(fallbackCodex.path)"), Comment(rawValue: captured))
        #expect(captured.contains("args=review --help"), Comment(rawValue: captured))
    }

    @Test
    func `Explicit disable wins over inherited wrapper ownership`() throws {
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

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let captured = try String(contentsOf: capturedEnvironment, encoding: .utf8)
        #expect(captured.contains("disabled=unset"))
        #expect(captured.contains("owner=unset"))
        #expect(captured.contains("args=\n"))
        #expect(!FileManager.default.fileExists(atPath: capturedCLIInvocations.path))
    }

    @Test
    func `Wrapper prefers trusted persistent hooks over untrusted session flags`() throws {
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

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let captured = try String(contentsOf: capturedEnvironment, encoding: .utf8)
        #expect(captured.contains("disabled=0"))
        #expect(captured.contains("owner=1"))
        #expect(captured.contains("args=\n"))
        let invocations = try String(contentsOf: capturedCLIInvocations, encoding: .utf8)
        #expect(invocations.contains("hooks codex install --yes"))
        #expect(!invocations.contains("hooks codex inject-args"))
    }

    @Test
    func `Injected hooks require wrapper ownership while persistent hooks respect disable`() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-injected-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = runCodexInjectArgsProcess(executablePath: cliPath, homeDirectory: root.path)
        #expect(result.status == 0, Comment(rawValue: result.stderr))

        let arguments = result.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        let hookConfigurations = arguments.filter { $0.hasPrefix("hooks.") }
        try #require(!hookConfigurations.isEmpty)
        for configuration in hookConfigurations {
            let marker = "command='''"
            let commandStart = try #require(configuration.range(of: marker)?.upperBound)
            let commandEnd = try #require(
                configuration.range(of: "'''", range: commandStart..<configuration.endIndex)?.lowerBound
            )
            let scriptPath = String(configuration[commandStart..<commandEnd])
            let body = try String(contentsOfFile: scriptPath, encoding: .utf8)
            #expect(body.contains("CMUX_CODEX_WRAPPER_HOOK_OWNER"))
            #expect(body.contains("= \"1\""))
        }
    }

    @Test
    func `Persistent hooks bind to native Codex process before wrapper fallback`() throws {
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
        #expect(install.status == 0, Comment(rawValue: install.stderr))
        let sessionStart = try #require(
            codexHookEntries(in: codexHome).first { $0.eventName == "SessionStart" }
        )
        #expect(sessionStart.body.contains(#"agent_pid="${PPID:-${CMUX_CODEX_PID:-}}""#))
    }

    @Test
    func `Persistent hooks do not pin one cmux instance into shared Codex config`() throws {
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
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            return try codexHookEntries(in: codexHome)
        }

        let firstHooks = try install(cli: firstCLI, socket: "/tmp/cmux-debug-first.sock")
        let secondHooks = try install(cli: secondCLI, socket: "/tmp/cmux-debug-second.sock")
        #expect(firstHooks.map(\.command).sorted() == secondHooks.map(\.command).sorted())
        for hook in secondHooks where hook.body.contains("hooks codex") {
            #expect(hook.body.contains("CMUX_CODEX_HOOK_CMUX_BIN"))
            #expect(hook.body.contains("CMUX_SOCKET_PATH"))
            #expect(!hook.body.contains(firstCLI.path))
            #expect(!hook.body.contains(secondCLI.path))
            #expect(!hook.body.contains("/tmp/cmux-debug-first.sock"))
            #expect(!hook.body.contains("/tmp/cmux-debug-second.sock"))
        }
    }

    @Test
    func `Hook scripts are immutable across concurrent cmux versions`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-content-address-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = runCodexInjectArgsProcess(
            executablePath: try bundledCLIPath(),
            homeDirectory: root.path
        )
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let arguments = result.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        let sessionStart = try #require(arguments.first { $0.hasPrefix("hooks.SessionStart=") })
        let marker = "command='''"
        let commandStart = try #require(sessionStart.range(of: marker)?.upperBound)
        let commandEnd = try #require(sessionStart.range(
            of: "'''",
            range: commandStart..<sessionStart.endIndex
        )?.lowerBound)
        let currentPath = String(sessionStart[commandStart..<commandEnd])
        let currentBody = try String(contentsOfFile: currentPath, encoding: .utf8)
        let legacyPath = URL(fileURLWithPath: currentPath)
            .deletingLastPathComponent()
            .appendingPathComponent("cmux-codex-hook-session-start.sh")
            .path

        #expect(currentPath != legacyPath)
        try "#!/bin/sh\nolder-path-fallback-body\n".write(
            toFile: legacyPath,
            atomically: true,
            encoding: .utf8
        )
        #expect(try String(contentsOfFile: currentPath, encoding: .utf8) == currentBody)
    }

    @Test
    func `Setup prunes legacy project dispatcher but preserves user hook`() throws {
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
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let promptHooks = try codexHookEntries(in: codexHome)
            .filter { $0.eventName == "UserPromptSubmit" }
        #expect(!promptHooks.contains { $0.command == legacyCommand })
        #expect(promptHooks.contains { $0.command == userCommand })
        #expect(promptHooks.filter { $0.body.contains("hooks codex prompt-submit") }.count == 1)
    }

    @Test
    func `Setup replaces older content-addressed and inline dispatchers`() throws {
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
        #expect(install.status == 0, Comment(rawValue: install.stderr))
        let hooks = try codexHookEntries(in: codexHome).filter { $0.eventName == "SessionStart" }
        #expect(!hooks.contains { $0.command == oldScript.path })
        #expect(!hooks.contains { $0.command == oldInlineDispatcher })
        #expect(hooks.contains { $0.command == "user-session-hook" })
        #expect(hooks.filter { $0.body.contains("hooks codex session-start") }.count == 1)
    }

    private func runCodexInjectArgsProcess(
        executablePath: String,
        homeDirectory: String
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
