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


// MARK: - Relay report-tty, ports kick, prompt refresh
extension ZshShellIntegrationHandoffTests {
    func testShellIntegrationRelayReportTTYUsesWorkspaceIDInZsh() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-relay-report-tty-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("cmux", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _CMUX_TTY_NAME=ttys777
            _cmux_report_tty_via_relay
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertTrue(
            output.contains(#"rpc surface.report_tty {"workspace_id":"11111111-1111-1111-1111-111111111111","tty_name":"ttys777","surface_id":"22222222-2222-2222-2222-222222222222"}"#),
            output
        )
    }

    func testShellIntegrationRelayPortsKickOmitsSurfaceIDUntilAvailableInZsh() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-relay-kick-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("cmux", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _cmux_ports_kick_via_relay refresh
            repeat 20; do
              [[ -s "\(logPath.path)" ]] && break
              sleep 0.05
            done
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "",
            ]
        )

        XCTAssertTrue(
            output.contains(#"rpc surface.ports_kick {"workspace_id":"11111111-1111-1111-1111-111111111111","reason":"refresh"}"#),
            output
        )
        XCTAssertFalse(output.contains("surface_id"), output)
    }

    func testShellIntegrationRelayPromptRefreshUsesRefreshReasonInZsh() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-relay-precmd-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("cmux", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=-999
            _cmux_precmd
            repeat 20; do
              [[ -s "\(logPath.path)" ]] && break
              sleep 0.05
            done
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertTrue(
            output.contains(#"rpc surface.ports_kick {"workspace_id":"11111111-1111-1111-1111-111111111111","reason":"refresh","surface_id":"22222222-2222-2222-2222-222222222222"}"#),
            output
        )
    }

    func testShellIntegrationRelayReportTTYUsesWorkspaceIDInBash() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-relay-report-tty-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("cmux", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _CMUX_TTY_NAME=ttys888
            _cmux_report_tty_via_relay
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertTrue(
            result.stdout.contains(#"rpc surface.report_tty {"workspace_id":"11111111-1111-1111-1111-111111111111","tty_name":"ttys888","surface_id":"22222222-2222-2222-2222-222222222222"}"#),
            result.stdout
        )
    }

    func testShellIntegrationRelayPreexecWorksBeforeSurfaceIDExistsInBash() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-relay-preexec-no-surface-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("cmux", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _CMUX_TTY_NAME=ttys889
            _CMUX_TTY_REPORTED=0
            _cmux_preexec_command "python3 -m http.server 8899"
            for _cmux_i in $(seq 1 20); do
              [ -s "\(logPath.path)" ] && break
              sleep 0.05
            done
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "",
            ]
        )

        XCTAssertTrue(
            result.stdout.contains(#"rpc surface.report_tty {"workspace_id":"11111111-1111-1111-1111-111111111111","tty_name":"ttys889"}"#),
            result.stdout
        )
        XCTAssertTrue(
            result.stdout.contains(#"rpc surface.ports_kick {"workspace_id":"11111111-1111-1111-1111-111111111111","reason":"command"}"#),
            result.stdout
        )
        XCTAssertFalse(result.stdout.contains(#""surface_id""#), result.stdout)
    }

    func testShellIntegrationRelayPromptRefreshUsesRefreshReasonInBashWithoutPromptNoise() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-relay-prompt-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("cmux", isDirectory: false),
            contents: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            : > "\(logPath.path)"
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=-999
            _cmux_prompt_command
            for _cmux_i in $(seq 1 20); do
              [ -s "\(logPath.path)" ] && break
              sleep 0.05
            done
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "127.0.0.1:64011",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertFalse(result.stderr.contains("_cmux_report_tmux_state"), result.stderr)
        XCTAssertTrue(
            result.stdout.contains(#"rpc surface.ports_kick {"workspace_id":"11111111-1111-1111-1111-111111111111","reason":"refresh","surface_id":"22222222-2222-2222-2222-222222222222"}"#),
            result.stdout
        )
    }

}
