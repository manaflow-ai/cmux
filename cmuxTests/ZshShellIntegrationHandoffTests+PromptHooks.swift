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


// MARK: - Prompt hooks, managed TERM, keyboard protocol resets
extension ZshShellIntegrationHandoffTests {
    func testGhosttyPromptHooksLoadWhenCmuxRequestsZshIntegration() throws {
        let output = try runInteractiveZsh(cmuxLoadGhosttyIntegration: true)

        XCTAssertTrue(output.contains("PRECMD=1"), output)
        XCTAssertTrue(output.contains("PREEXEC=1"), output)
        XCTAssertTrue(output.contains("PRECMDS=_ghostty_precmd"), output)
    }

    func testGhosttyPromptHooksDoNotLoadWithoutCmuxHandoffFlag() throws {
        let output = try runInteractiveZsh(cmuxLoadGhosttyIntegration: false)

        XCTAssertTrue(output.contains("PRECMD=0"), output)
        XCTAssertTrue(output.contains("PREEXEC=0"), output)
    }

    func testGhosttySemanticPatchRetriesAfterDeferredInitCreatesLiveHooks() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: true,
            cmuxLoadShellIntegration: true,
            command: """
            _cmux_patch_ghostty_semantic_redraw
            (( $+functions[_ghostty_deferred_init] )) && _ghostty_deferred_init >/dev/null 2>&1
            _cmux_patch_ghostty_semantic_redraw
            print -r -- "PRECMD_BODY=${functions[_ghostty_precmd]}"
            print -r -- "PREEXEC_BODY=${functions[_ghostty_preexec]}"
            """
        )

        XCTAssertTrue(output.contains("PRECMD_BODY="), output)
        XCTAssertTrue(output.contains("PREEXEC_BODY="), output)
        XCTAssertTrue(output.contains("133;A;redraw=last;cl=line"), output)
    }

    func testShellIntegrationWinchGuardDoesNotPrintSpacerLineOnResize() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            print -r -- BEFORE
            TRAPWINCH
            print -r -- AFTER
            """
        )

        XCTAssertEqual(output, "BEFORE\nAFTER", output)
    }

    func testShellIntegrationPreservesStartupTermForThemeSelectionBeforeRestoringManagedTerm() throws {
        let output = try runPromptInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            print -r -- "CMD=$TERM|${CMUX_ZSH_RESTORE_TERM-unset}" >> "$CMUX_TEST_OUTPUT"
            """,
            userZshRCContents: """
            export CMUX_STARTUP_THEME_TERM="$TERM"
            if [[ $TERM = (*256color|*rxvt*) ]]; then
              export CMUX_STARTUP_THEME_BRANCH=extended
            else
              export CMUX_STARTUP_THEME_BRANCH=basic
            fi

            cmux_test_ready() {
              [[ -e "$CMUX_TEST_READY" ]] && return 0
              print -r -- "PRE=$CMUX_STARTUP_THEME_TERM|$CMUX_STARTUP_THEME_BRANCH|$TERM|${CMUX_ZSH_RESTORE_TERM-unset}" > "$CMUX_TEST_OUTPUT"
              : > "$CMUX_TEST_READY"
              precmd_functions=(${precmd_functions:#cmux_test_ready})
            }
            precmd_functions+=(cmux_test_ready)
            """
        )

        XCTAssertEqual(
            output,
            "PRE=xterm-ghostty|basic|xterm-ghostty|xterm-256color\nCMD=xterm-256color|unset",
            output
        )
    }

    func testShellIntegrationDoesNotSpoofManagedTermForInteractiveCommandMode() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            print -r -- "$CMUX_STARTUP_TERM|$TERM|${CMUX_ZSH_RESTORE_TERM-unset}"
            """,
            userZshRCContents: """
            export CMUX_STARTUP_TERM="$TERM"
            """
        )

        XCTAssertEqual(output, "xterm-256color|xterm-256color|unset", output)
    }

    func testShellIntegrationDoesNotSpoofManagedTermWhenIntegrationDisabled() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: false,
            command: """
            print -r -- "$CMUX_STARTUP_TERM|$TERM|${CMUX_ZSH_RESTORE_TERM-unset}"
            """,
            userZshRCContents: """
            export CMUX_STARTUP_TERM="$TERM"
            """
        )

        XCTAssertEqual(output, "xterm-256color|xterm-256color|unset", output)
    }

    func testShellIntegrationDoesNotSpoofManagedTermWhenUserZshEnvDisablesIntegration() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            print -r -- "$CMUX_STARTUP_TERM|$TERM|${CMUX_ZSH_RESTORE_TERM-unset}|${CMUX_SHELL_INTEGRATION:-unset}"
            """,
            userZshEnvContents: """
            export CMUX_SHELL_INTEGRATION=0
            """,
            userZshRCContents: """
            export CMUX_STARTUP_TERM="$TERM"
            """
        )

        XCTAssertEqual(output, "xterm-256color|xterm-256color|unset|0", output)
    }

    func testShellIntegrationNormalizesClaudeConfigDirAfterUserZshrc() throws {
        let output = try runPromptInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            print -r -- "CMD=$CLAUDE_CONFIG_DIR" >> "$CMUX_TEST_OUTPUT"
            """,
            userZshRCContents: """
            mkdir -p "$HOME/.subrouter/codex/claude/_p1775010019397"
            ln -s "$HOME/.subrouter/codex" "$HOME/.codex-accounts"
            export CLAUDE_CONFIG_DIR="$HOME/.subrouter/codex/claude/_p1775010019397"

            cmux_test_ready() {
              [[ -e "$CMUX_TEST_READY" ]] && return 0
              print -r -- "PRE=$CLAUDE_CONFIG_DIR" > "$CMUX_TEST_OUTPUT"
              : > "$CMUX_TEST_READY"
              precmd_functions=(${precmd_functions:#cmux_test_ready})
            }
            precmd_functions+=(cmux_test_ready)
            """
        )

        XCTAssertTrue(
            output.contains("PRE=") && output.contains("CMD="),
            output
        )
        for line in output.split(separator: "\n") {
            XCTAssertTrue(
                line.hasSuffix("/.codex-accounts/claude/_p1775010019397"),
                output
            )
        }
        XCTAssertFalse(output.contains("/.subrouter/codex/claude/"), output)
    }

    func testShellIntegrationDoesNotRegisterPromptTimeTermRestoreHooks() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            print -r -- "${(j:,:)precmd_functions}"
            """
        )

        XCTAssertEqual(
            output,
            "_cmux_precmd,_cmux_fix_path",
            output
        )
    }

    func testShellIntegrationRestoresManagedTermDuringPreexec() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            _cmux_preexec 'echo $TERM'
            print -r -- "$TERM|${CMUX_ZSH_RESTORE_TERM-unset}"
            """,
            extraEnvironment: [
                "TERM": "xterm-ghostty",
                "CMUX_ZSH_RESTORE_TERM": "xterm-256color",
            ]
        )

        XCTAssertEqual(
            output,
            "xterm-256color|unset",
            output
        )
    }

    func testZshPromptResetsTerminalKeyboardProtocols() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=$(_cmux_now)
            _cmux_precmd
            """,
            extraEnvironment: [
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_BUNDLED_CLI_PATH": "/usr/bin/true",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_TEST_FORCE_KITTY_RESET": "1",
            ]
        )

        XCTAssertEqual(output, "\u{1B}[>m\u{1B}[<8u")
    }

    func testBashPromptResetsTerminalKeyboardProtocols() throws {
        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=$(_cmux_now)
            _cmux_prompt_command
            """,
            extraEnvironment: [
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_BUNDLED_CLI_PATH": "/usr/bin/true",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_TEST_FORCE_KITTY_RESET": "1",
            ]
        )

        XCTAssertEqual(result.stdout, "\u{1B}[>m\u{1B}[<8u")
    }

    private func runPromptInteractiveZsh(
        cmuxLoadGhosttyIntegration: Bool,
        cmuxLoadShellIntegration: Bool,
        command: String,
        extraEnvironment: [String: String] = [:],
        userZshEnvContents: String? = nil,
        userZshRCContents: String? = nil
    ) throws -> String {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-prompt-integration-\(UUID().uuidString)")
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
        let readyPath = root.appendingPathComponent("ready", isDirectory: false)
        let outputPath = root.appendingPathComponent("output.log", isDirectory: false)

        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            let message = "openpty failed: \(String(cString: strerror(errno)))"
            XCTFail(message)
            throw NSError(
                domain: "ZshShellIntegrationHandoffTests",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-i"]
        process.environment = [
            "HOME": root.path,
            "TERM": "xterm-256color",
            "SHELL": "/bin/zsh",
            "USER": NSUserName(),
            "ZDOTDIR": cmuxZdotdir.path,
            "CMUX_ZSH_ZDOTDIR": userZdotdir.path,
            "CMUX_SHELL_INTEGRATION": "0",
            "GHOSTTY_RESOURCES_DIR": ghosttyResources.path,
            "CMUX_TEST_READY": readyPath.path,
            "CMUX_TEST_OUTPUT": outputPath.path,
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

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let terminalOutputLock = NSLock()
        var terminalOutputData = Data()
        masterHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            terminalOutputLock.lock()
            terminalOutputData.append(data)
            terminalOutputLock.unlock()
        }
        defer { masterHandle.readabilityHandler = nil }

        func terminalOutputSnapshot() -> String {
            terminalOutputLock.lock()
            defer { terminalOutputLock.unlock() }
            return String(data: terminalOutputData, encoding: .utf8) ?? ""
        }

        try process.run()
        slaveHandle.closeFile()

        let readyDeadline = Date().addingTimeInterval(5)
        while !fileManager.fileExists(atPath: readyPath.path) && Date() < readyDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if !fileManager.fileExists(atPath: readyPath.path) {
            process.terminate()
            process.waitUntilExit()
            let terminalOutput = terminalOutputSnapshot()
            let message = "Timed out waiting for interactive zsh prompt: \(terminalOutput)"
            XCTFail(message)
            throw NSError(
                domain: "ZshShellIntegrationHandoffTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        masterHandle.write(Data((command + "\nexit\n").utf8))

        let exitDeadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < exitDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            let terminalOutput = terminalOutputSnapshot()
            let message = "Timed out waiting for interactive zsh to exit: \(terminalOutput)"
            XCTFail(message)
            throw NSError(
                domain: "ZshShellIntegrationHandoffTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let terminalOutput = terminalOutputSnapshot()
        XCTAssertEqual(process.terminationStatus, 0, terminalOutput)
        return (try? String(contentsOf: outputPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

}
