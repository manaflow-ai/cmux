import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyTerminalStartupEnvironmentTests: XCTestCase {
    func testTerminalSessionBackendDefaultsToNative() {
        let suiteName = "cmux.tests.session-backend.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(TerminalSessionBackendSettings.backend(defaults: defaults), .native)
    }

    func testTerminalSessionBackendResolvesZellijForCleanLocalTerminal() throws {
        let suiteName = "cmux.tests.session-backend.zellij.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        TerminalSessionBackendSettings.setBackend(.zellij, defaults: defaults)
        let identity = try XCTUnwrap(
            TerminalSessionBackendSettings.resolvedIdentity(
                explicit: nil,
                defaultName: "cmux-workspace-surface",
                hasExplicitStartup: false,
                defaults: defaults,
                environment: [:]
            )
        )

        XCTAssertEqual(identity.backend, .zellij)
        XCTAssertEqual(identity.name, "cmux-workspace-surface")
    }

    func testTerminalSessionBackendSkipsZellijForExplicitStartupAndNestedZellij() {
        let suiteName = "cmux.tests.session-backend.skip.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        TerminalSessionBackendSettings.setBackend(.zellij, defaults: defaults)

        XCTAssertNil(
            TerminalSessionBackendSettings.resolvedIdentity(
                explicit: nil,
                defaultName: "cmux-explicit",
                hasExplicitStartup: true,
                defaults: defaults,
                environment: [:]
            )
        )
        XCTAssertNil(
            TerminalSessionBackendSettings.resolvedIdentity(
                explicit: nil,
                defaultName: "cmux-nested",
                hasExplicitStartup: false,
                defaults: defaults,
                environment: ["ZELLIJ": "1"]
            )
        )
        let explicitIdentity = TerminalSessionIdentity(backend: .zellij, name: "cmux-restored")
        XCTAssertEqual(
            TerminalSessionBackendSettings.resolvedIdentity(
                explicit: explicitIdentity,
                defaultName: "cmux-nested",
                hasExplicitStartup: false,
                defaults: defaults,
                environment: ["ZELLIJ": "1"]
            ),
            explicitIdentity
        )
    }

    func testZellijAttachCommandUsesStableSessionAndPreservationOptions() throws {
        let command = try XCTUnwrap(
            TerminalSessionBackendSettings.zellijAttachCommand(
                identity: TerminalSessionIdentity(backend: .zellij, name: "cmux pane's session"),
                workingDirectory: "/tmp/cmux repo"
            )
        )

        XCTAssertEqual(
            command,
            "exec 'zellij' 'attach' '--create' '--force-run-commands' 'cmux pane'\"'\"'s session' 'options' '--on-force-close' 'detach' '--session-serialization' 'true' '--pane-viewport-serialization' 'true' '--scrollback-lines-to-serialize' '0' '--serialization-interval' '60' '--support-kitty-keyboard-protocol' 'true' '--default-cwd' '/tmp/cmux repo'"
        )
    }

    func testZellijInheritedConfigScrubsGeneratedStartup() {
        var config = CmuxSurfaceConfigTemplate()
        config.fontSize = 18
        config.workingDirectory = "/tmp/cmux"
        config.command = "exec 'zellij' 'attach' '--create' 'cmux-session'"
        config.initialInput = "echo stale\n"
        config.waitAfterCommand = true
        config.environmentVariables = ["CMUX_KEEP": "1"]

        TerminalSessionBackendSettings.sanitizeInheritedConfig(
            &config,
            sourceIdentity: TerminalSessionIdentity(backend: .zellij, name: "cmux-session")
        )

        XCTAssertEqual(config.fontSize, 18)
        XCTAssertEqual(config.workingDirectory, "/tmp/cmux")
        XCTAssertEqual(config.environmentVariables, ["CMUX_KEEP": "1"])
        XCTAssertNil(config.command)
        XCTAssertNil(config.initialInput)
        XCTAssertFalse(config.waitAfterCommand)
    }

    @MainActor
    func testTerminalSurfaceStoresExplicitZellijSessionIdentity() throws {
        let workspaceId = UUID()
        let identity = TerminalSessionIdentity(backend: .zellij, name: "cmux-\(workspaceId.uuidString)")
        let surface = TerminalSurface(
            tabId: workspaceId,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            terminalSessionIdentity: identity
        )
        defer { TerminalSurfaceRegistry.shared.unregister(surface) }

        XCTAssertEqual(surface.debugTerminalSessionIdentityForTesting(), identity)
    }

    @MainActor
    func testTerminalSurfaceStartupEnvironmentIncludesCmuxContextValues() throws {
        let workspaceId = UUID()
        let surface = TerminalSurface(
            tabId: workspaceId,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil
        )
        defer { TerminalSurfaceRegistry.shared.unregister(surface) }

        let expectedContextValues = [
            "CMUX_WORKSPACE_ID": workspaceId.uuidString,
            "CMUX_SURFACE_ID": surface.id.uuidString,
            "CMUX_TAB_ID": workspaceId.uuidString,
            "CMUX_PANEL_ID": surface.id.uuidString
        ]

        for (key, expectedValue) in expectedContextValues {
            let value = try XCTUnwrap(surface.startupEnvironmentValue(key), "\(key) should be present")
            XCTAssertFalse(value.isEmpty, "\(key) should be non-empty")
            XCTAssertEqual(value, expectedValue)
        }

        let socketPath = try XCTUnwrap(
            surface.startupEnvironmentValue("CMUX_SOCKET_PATH"),
            "CMUX_SOCKET_PATH should be present"
        )
        XCTAssertFalse(socketPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

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

    func testApplyManagedGitWatchEnvironmentDisablesShellGitWatch() {
        var environment: [String: String] = [:]
        var protectedKeys: Set<String> = []

        TerminalSurface.applyManagedGitWatchEnvironment(
            watchGitStatusEnabled: false,
            to: &environment,
            protectedKeys: &protectedKeys
        )

        XCTAssertEqual(environment["CMUX_NO_GIT_WATCH"], "1")
        XCTAssertTrue(protectedKeys.contains("CMUX_NO_GIT_WATCH"))
    }

    func testApplyManagedGitWatchEnvironmentClearsInheritedOptOutWhenEnabled() {
        var environment = [
            "CMUX_NO_GIT_WATCH": "1"
        ]
        var protectedKeys: Set<String> = []

        TerminalSurface.applyManagedGitWatchEnvironment(
            watchGitStatusEnabled: true,
            to: &environment,
            protectedKeys: &protectedKeys
        )
        let merged = TerminalSurface.mergedStartupEnvironment(
            base: environment,
            protectedKeys: protectedKeys,
            additionalEnvironment: [
                "CMUX_NO_GIT_WATCH": "1"
            ],
            initialEnvironmentOverrides: [
                "CMUX_NO_GIT_WATCH": "1"
            ]
        )

        XCTAssertEqual(merged["CMUX_NO_GIT_WATCH"], "")
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
