import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyTerminalStartupEnvironmentTests: XCTestCase {
    func testApplyManagedTerminalIdentityEnvironmentOverridesInheritedValues() {
        var environment = [
            "TERM": "xterm-ghostty",
            "COLORTERM": "24bit",
            "TERM_PROGRAM": "Apple_Terminal",
            "CUSTOM_FLAG": "1"
        ]
        var protectedKeys: Set<String> = []

        TerminalSurface.applyManagedTerminalIdentityEnvironment(
            to: &environment,
            protectedKeys: &protectedKeys
        )

        XCTAssertEqual(environment["TERM"], TerminalSurface.managedTerminalType)
        XCTAssertEqual(environment["COLORTERM"], TerminalSurface.managedColorTerm)
        XCTAssertEqual(environment["TERM_PROGRAM"], TerminalSurface.managedTerminalProgram)
        XCTAssertEqual(environment["CUSTOM_FLAG"], "1")
        XCTAssertTrue(protectedKeys.contains("TERM"))
        XCTAssertTrue(protectedKeys.contains("COLORTERM"))
        XCTAssertTrue(protectedKeys.contains("TERM_PROGRAM"))
    }

    func testMergedStartupEnvironmentAllowsSessionReplayAndInitialEnvCMUXKeys() {
        let replayPath = "/tmp/cmux-replay-\(UUID().uuidString)"
        let merged = TerminalSurface.mergedStartupEnvironment(
            base: [
                "PATH": "/usr/bin",
                "CMUX_SURFACE_ID": "managed-surface"
            ],
            protectedKeys: ["PATH", "CMUX_SURFACE_ID"],
            additionalEnvironment: [
                SessionScrollbackReplayStore.environmentKey: replayPath
            ],
            initialEnvironmentOverrides: [
                "CMUX_INITIAL_ENV_TOKEN": "token-123"
            ]
        )

        XCTAssertEqual(merged[SessionScrollbackReplayStore.environmentKey], replayPath)
        XCTAssertEqual(merged["CMUX_INITIAL_ENV_TOKEN"], "token-123")
    }

    func testMergedStartupEnvironmentProtectsManagedKeysOnly() {
        let merged = TerminalSurface.mergedStartupEnvironment(
            base: [
                "PATH": "/usr/bin",
                "CMUX_SURFACE_ID": "managed-surface"
            ],
            protectedKeys: ["PATH", "CMUX_SURFACE_ID"],
            additionalEnvironment: [
                "CMUX_SURFACE_ID": "user-surface",
                "CUSTOM_FLAG": "1"
            ],
            initialEnvironmentOverrides: [
                "PATH": "/tmp/bin",
                "CMUX_SURFACE_ID": "override-surface"
            ]
        )

        XCTAssertEqual(merged["PATH"], "/usr/bin")
        XCTAssertEqual(merged["CMUX_SURFACE_ID"], "managed-surface")
        XCTAssertEqual(merged["CUSTOM_FLAG"], "1")
    }

    func testMergedStartupEnvironmentProtectsManagedTerminalIdentity() {
        var baseEnvironment = [
            "PATH": "/usr/bin"
        ]
        var protectedKeys: Set<String> = ["PATH"]
        TerminalSurface.applyManagedTerminalIdentityEnvironment(
            to: &baseEnvironment,
            protectedKeys: &protectedKeys
        )

        let merged = TerminalSurface.mergedStartupEnvironment(
            base: baseEnvironment,
            protectedKeys: protectedKeys,
            additionalEnvironment: [
                "TERM": "xterm-ghostty",
                "COLORTERM": "24bit",
                "TERM_PROGRAM": "Apple_Terminal"
            ],
            initialEnvironmentOverrides: [
                "TERM": "screen-256color",
                "COLORTERM": "false",
                "TERM_PROGRAM": "WarpTerminal"
            ]
        )

        XCTAssertEqual(merged["TERM"], TerminalSurface.managedTerminalType)
        XCTAssertEqual(merged["COLORTERM"], TerminalSurface.managedColorTerm)
        XCTAssertEqual(merged["TERM_PROGRAM"], TerminalSurface.managedTerminalProgram)
    }

    func testMergedStartupEnvironmentPreservesThirdPartyClaudeApiEnvironment() {
        let merged = TerminalSurface.mergedStartupEnvironment(
            base: [
                "CLAUDE_CONFIG_DIR": "/tmp/claude-config",
                "ANTHROPIC_API_KEY": "stale-api-key",
                "ANTHROPIC_AUTH_TOKEN": "third-party-auth-token",
                "ANTHROPIC_BASE_URL": "https://api.example.test",
                "ANTHROPIC_MODEL": "stale-model",
                "CUSTOM_FLAG": "1"
            ],
            protectedKeys: [],
            additionalEnvironment: [:],
            initialEnvironmentOverrides: [:]
        )

        XCTAssertEqual(merged["CLAUDE_CONFIG_DIR"], "/tmp/claude-config")
        XCTAssertEqual(merged["ANTHROPIC_API_KEY"], "")
        XCTAssertEqual(merged["ANTHROPIC_AUTH_TOKEN"], "third-party-auth-token")
        XCTAssertEqual(merged["ANTHROPIC_BASE_URL"], "https://api.example.test")
        XCTAssertEqual(merged["ANTHROPIC_MODEL"], "")
        XCTAssertEqual(merged["CUSTOM_FLAG"], "1")
    }

    func testMergedStartupEnvironmentDoesNotMaskAmbientThirdPartyClaudeApiEnvironment() {
        let merged = TerminalSurface.mergedStartupEnvironment(
            base: [
                "CUSTOM_FLAG": "1"
            ],
            protectedKeys: [],
            additionalEnvironment: [:],
            initialEnvironmentOverrides: [:],
            ambientEnvironment: [
                "CLAUDE_CONFIG_DIR": "/tmp/ambient-claude-config",
                "ANTHROPIC_API_KEY": "ambient-api-key",
                "ANTHROPIC_AUTH_TOKEN": "ambient-auth-token",
                "ANTHROPIC_BASE_URL": "https://api.example.test",
                "ANTHROPIC_MODEL": "ambient-model"
            ]
        )

        XCTAssertNil(merged["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(merged["ANTHROPIC_API_KEY"], "")
        XCTAssertNil(merged["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(merged["ANTHROPIC_BASE_URL"])
        XCTAssertEqual(merged["ANTHROPIC_MODEL"], "")
        XCTAssertEqual(merged["CUSTOM_FLAG"], "1")
    }

    func testMergedStartupEnvironmentAllowsExplicitClaudeAuthSelectionOverrides() {
        let merged = TerminalSurface.mergedStartupEnvironment(
            base: [
                "CLAUDE_CONFIG_DIR": "/tmp/stale-claude-config",
                "ANTHROPIC_API_KEY": "stale-api-key"
            ],
            protectedKeys: [],
            additionalEnvironment: [
                "CLAUDE_CONFIG_DIR": "/tmp/resume-claude-config"
            ],
            initialEnvironmentOverrides: [
                "ANTHROPIC_API_KEY": "explicit-api-key"
            ],
            ambientEnvironment: [
                "ANTHROPIC_MODEL": "ambient-model"
            ]
        )

        XCTAssertEqual(merged["CLAUDE_CONFIG_DIR"], "/tmp/resume-claude-config")
        XCTAssertEqual(merged["ANTHROPIC_API_KEY"], "explicit-api-key")
        XCTAssertEqual(merged["ANTHROPIC_MODEL"], "")
    }
}
