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


// MARK: - Tmux environment publication and TTY reporting
extension ZshShellIntegrationHandoffTests {
    func testShellIntegrationPublishesOnlyWorkspaceScopedCmuxEnvironmentToTmuxServerAutomatically() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-tmux-publish-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("tmux.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("tmux", isDirectory: false),
            contents: """
            #!/bin/sh
            if [ "$1" = "show-environment" ] && [ "$2" = "-g" ]; then
              exit 0
            fi
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        _ = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: "_cmux_preexec tmux; print -r -- READY",
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "/tmp/cmux-current.sock",
                "CMUX_TAG": "feat-tmux-notification-attention-state",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_TAB_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        let log = (try? String(contentsOf: logPath, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("set-environment -g CMUX_TAG feat-tmux-notification-attention-state"), log)
        XCTAssertTrue(log.contains("set-environment -g CMUX_SOCKET_PATH /tmp/cmux-current.sock"), log)
        XCTAssertTrue(log.contains("set-environment -g CMUX_WORKSPACE_ID 11111111-1111-1111-1111-111111111111"), log)
        XCTAssertFalse(log.contains("set-environment -g CMUX_SURFACE_ID"), log)
        XCTAssertFalse(log.contains("set-environment -g CMUX_PANEL_ID"), log)
    }

    func testShellIntegrationClearsStaleSurfaceScopedTmuxEnvironmentAutomatically() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-tmux-clear-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let logPath = root.appendingPathComponent("tmux.log", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("tmux", isDirectory: false),
            contents: """
            #!/bin/sh
            if [ "$1" = "show-environment" ] && [ "$2" = "-g" ]; then
              printf '%s\\n' 'CMUX_SURFACE_ID=99999999-9999-9999-9999-999999999999'
              printf '%s\\n' 'CMUX_PANEL_ID=99999999-9999-9999-9999-999999999999'
              exit 0
            fi
            printf '%s\\n' "$*" >> "\(logPath.path)"
            exit 0
            """
        )

        _ = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: "_cmux_preexec tmux; print -r -- READY",
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": "/tmp/cmux-current.sock",
                "CMUX_TAG": "feat-tmux-notification-attention-state",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_TAB_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        let log = (try? String(contentsOf: logPath, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("set-environment -gu CMUX_SURFACE_ID"), log)
        XCTAssertTrue(log.contains("set-environment -gu CMUX_PANEL_ID"), log)
    }

    func testShellIntegrationRefreshesWorkspaceScopedCmuxEnvironmentFromTmuxWithoutOverwritingSurfaceScope() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-tmux-refresh-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableScript(
            at: binDir.appendingPathComponent("tmux", isDirectory: false),
            contents: """
            #!/bin/sh
            if [ "$1" = "show-environment" ] && [ "$2" = "-g" ]; then
              printf '%s\\n' 'CMUX_SOCKET_PATH=/tmp/cmux-current.sock'
              printf '%s\\n' 'CMUX_TAG=feat-tmux-notification-attention-state'
              printf '%s\\n' 'CMUX_WORKSPACE_ID=11111111-1111-1111-1111-111111111111'
              printf '%s\\n' 'CMUX_SURFACE_ID=99999999-9999-9999-9999-999999999999'
              printf '%s\\n' 'CMUX_TAB_ID=11111111-1111-1111-1111-111111111111'
              printf '%s\\n' 'CMUX_PANEL_ID=99999999-9999-9999-9999-999999999999'
              exit 0
            fi
            exit 0
            """
        )

        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: "_cmux_precmd; print -r -- \"$CMUX_TAG|$CMUX_SOCKET_PATH|$CMUX_WORKSPACE_ID|$CMUX_SURFACE_ID|$CMUX_PANEL_ID\"",
            extraEnvironment: [
                "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "TMUX": "/tmp/tmux-stale,123,0",
                "CMUX_SOCKET_PATH": "/tmp/cmux-stale.sock",
                "CMUX_TAG": "feat-tmux-integration-experiments",
                "CMUX_WORKSPACE_ID": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                "CMUX_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_TAB_ID": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertEqual(
            output,
            "feat-tmux-notification-attention-state|/tmp/cmux-current.sock|11111111-1111-1111-1111-111111111111|22222222-2222-2222-2222-222222222222|22222222-2222-2222-2222-222222222222"
        )
    }

    func testShellIntegrationReportsTTYFromTmuxWithoutUsingPanelScope() throws {
        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            _CMUX_TTY_NAME=ttys999
            print -r -- "$(_cmux_report_tty_payload)"
            """,
            extraEnvironment: [
                "TMUX": "/tmp/tmux-current,123,0",
                "CMUX_TAB_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_PANEL_ID": "99999999-9999-9999-9999-999999999999",
            ]
        )

        XCTAssertEqual(output, "report_tty ttys999 --tab=11111111-1111-1111-1111-111111111111")
    }

}
