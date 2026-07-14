import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CodexHookWriterOwnershipRegressionTests {
    @Test func wrapperSuppressesPersistentCmuxHooksAndOwnsInjectedHooks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-owner-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux", isDirectory: false)
        let fakeCodex = root.appendingPathComponent("codex-real", isDirectory: false)
        let capturedEnvironment = root.appendingPathComponent("codex-environment.txt", isDirectory: false)
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
            "case \" $* \" in",
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
            ],
            timeout: 3
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let captured = try String(contentsOf: capturedEnvironment, encoding: .utf8)
        #expect(captured.contains("disabled=1"))
        #expect(captured.contains("owner=1"))
        #expect(captured.contains("args=--yolo"))
    }

    @Test func injectedHooksRequireWrapperOwnershipWhilePersistentHooksRespectDisable() throws {
        let cliPath = try bundledCLIPath()
        let result = runCodexInjectArgsProcess(executablePath: cliPath)
        #expect(result.status == 0, Comment(rawValue: result.stderr))

        let arguments = result.stdout.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
        let hookConfigurations = arguments.filter { $0.hasPrefix("hooks.") }
        #expect(!hookConfigurations.isEmpty)
        for configuration in hookConfigurations {
            let marker = "command='''"
            let commandStart = try #require(configuration.range(of: marker)?.upperBound)
            let commandEnd = try #require(configuration.range(of: "'''", range: commandStart..<configuration.endIndex)?.lowerBound)
            let scriptPath = String(configuration[commandStart..<commandEnd])
            let body = try String(contentsOfFile: scriptPath, encoding: .utf8)
            #expect(body.contains("CMUX_CODEX_WRAPPER_HOOK_OWNER"))
            #expect(body.contains("= \"1\""))
        }
    }

    @Test func setupPrunesLegacyProjectDispatcherButPreservesUserHook() throws {
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

    private func runCodexInjectArgsProcess(executablePath: String) -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["hooks", "codex", "inject-args"]
        process.environment = [
            "HOME": NSHomeDirectory(),
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
}
