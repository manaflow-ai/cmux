import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CodexHookWriterOwnershipRegressionTests: XCTestCase {
    func testWrapperSuppressesPersistentCmuxHooksAndOwnsInjectedHooks() throws {
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

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let captured = try String(contentsOf: capturedEnvironment, encoding: .utf8)
        XCTAssertTrue(captured.contains("disabled=1"))
        XCTAssertTrue(captured.contains("owner=1"))
        XCTAssertTrue(captured.contains("args=--yolo"))
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

    func testHookScriptsAreImmutableAcrossConcurrentCmuxVersions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-content-address-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let currentBody = "current-owner-gated-body"
        let olderBody = "older-path-fallback-body"
        let currentPath = try XCTUnwrap(CMUXCLI.writeCodexHookScript(
            subcommand: "session-start",
            body: currentBody,
            in: root
        ))
        let olderPath = try XCTUnwrap(CMUXCLI.writeCodexHookScript(
            subcommand: "session-start",
            body: olderBody,
            in: root
        ))

        XCTAssertNotEqual(currentPath, olderPath)
        XCTAssertEqual(try String(contentsOfFile: currentPath, encoding: .utf8), "#!/bin/sh\n\(currentBody)\n")
        XCTAssertEqual(try String(contentsOfFile: olderPath, encoding: .utf8), "#!/bin/sh\n\(olderBody)\n")
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

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
    }
}
