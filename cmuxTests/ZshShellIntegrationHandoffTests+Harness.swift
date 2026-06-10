@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Interactive zsh/bash harness
extension ZshShellIntegrationHandoffTests {
    func runInteractiveZsh(cmuxLoadGhosttyIntegration: Bool) throws -> String {
        try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: cmuxLoadGhosttyIntegration,
            cmuxLoadShellIntegration: false,
            command: "(( $+functions[_ghostty_deferred_init] )) && _ghostty_deferred_init >/dev/null 2>&1; " +
                "print -r -- \"PRECMD=${+functions[_ghostty_precmd]} " +
                "PREEXEC=${+functions[_ghostty_preexec]} PRECMDS=${(j:,:)precmd_functions}\""
        )
    }

    func runInteractiveZsh(
        cmuxLoadGhosttyIntegration: Bool,
        cmuxLoadShellIntegration: Bool,
        command: String,
        extraEnvironment: [String: String] = [:],
        userZshEnvContents: String? = nil,
        userZshRCContents: String? = nil
    ) throws -> String {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-shell-integration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let userZdotdir = root.appendingPathComponent("zdotdir")
        try fileManager.createDirectory(at: userZdotdir, withIntermediateDirectories: true)
        var userZshEnvFileContents = "\n"
        if let path = extraEnvironment["PATH"] {
            let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
            userZshEnvFileContents = "export PATH=\"\(escaped)\"\n"
        }
        if let userZshEnvContents {
            if !userZshEnvFileContents.hasSuffix("\n") {
                userZshEnvFileContents.append("\n")
            }
            userZshEnvFileContents.append(userZshEnvContents)
            if !userZshEnvFileContents.hasSuffix("\n") {
                userZshEnvFileContents.append("\n")
            }
        }
        try userZshEnvFileContents.write(
            to: userZdotdir.appendingPathComponent(".zshenv"),
            atomically: true,
            encoding: .utf8
        )
        if let userZshRCContents {
            try userZshRCContents.write(
                to: userZdotdir.appendingPathComponent(".zshrc"),
                atomically: true,
                encoding: .utf8
            )
        }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cmuxZdotdir = repoRoot.appendingPathComponent("Resources/shell-integration")
        let ghosttyResources = repoRoot.appendingPathComponent("ghostty/src")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-i",
            "-c", command
        ]
        process.environment = [
            "HOME": root.path,
            "TERM": "xterm-256color",
            "SHELL": "/bin/zsh",
            "USER": NSUserName(),
            "ZDOTDIR": cmuxZdotdir.path,
            "CMUX_ZSH_ZDOTDIR": userZdotdir.path,
            "CMUX_SHELL_INTEGRATION": "0",
            "GHOSTTY_RESOURCES_DIR": ghosttyResources.path,
        ]
        if cmuxLoadGhosttyIntegration {
            process.environment?["CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"] = "1"
        }
        if cmuxLoadShellIntegration {
            process.environment?["CMUX_SHELL_INTEGRATION"] = "1"
            process.environment?["CMUX_SHELL_INTEGRATION_DIR"] = cmuxZdotdir.path
            process.environment?["CMUX_SOCKET_PATH"] = root.appendingPathComponent("cmux-test.sock").path
            process.environment?["CMUX_TAB_ID"] = "tab-test"
            process.environment?["CMUX_PANEL_ID"] = "panel-test"
        }
        for (key, value) in extraEnvironment {
            process.environment?[key] = value
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("Timed out waiting for zsh to exit")
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, error)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func runInteractiveBash(
        cmuxLoadShellIntegration: Bool,
        command: String,
        extraEnvironment: [String: String] = [:]
    ) throws -> (stdout: String, stderr: String) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-shell-integration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integrationPath = repoRoot.appendingPathComponent("Resources/shell-integration/cmux-bash-integration.bash")
        let rcfilePath = root.appendingPathComponent(".bashrc")
        let rcfileContents: String = {
            guard cmuxLoadShellIntegration else { return ":\n" }
            return """
            . "\(integrationPath.path)"
            """
        }()
        try rcfileContents.write(to: rcfilePath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "--noprofile",
            "--rcfile", rcfilePath.path,
            "-i",
            "-c", command
        ]
        process.environment = [
            "HOME": root.path,
            "TERM": "xterm-256color",
            "SHELL": "/bin/bash",
            "USER": NSUserName(),
        ]
        if cmuxLoadShellIntegration {
            process.environment?["CMUX_SOCKET_PATH"] = root.appendingPathComponent("cmux-test.sock").path
            process.environment?["CMUX_TAB_ID"] = "tab-test"
            process.environment?["CMUX_PANEL_ID"] = "panel-test"
        }
        for (key, value) in extraEnvironment {
            process.environment?[key] = value
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("Timed out waiting for bash to exit")
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, error)
        return (
            stdout: output.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: error.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func writeExecutableScript(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

}
