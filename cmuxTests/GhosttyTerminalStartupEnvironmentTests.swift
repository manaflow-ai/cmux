import Foundation
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif
@Suite(.serialized)
struct GhosttyTerminalStartupEnvironmentTests {
    @MainActor
    @Test
    func testTerminalSurfaceStartupEnvironmentIncludesCmuxContextValues() throws {
        let workspaceId = UUID()
        let surface = TerminalSurface(
            tabId: workspaceId,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil
        )
        defer { GhosttyApp.terminalSurfaceRegistry.unregister(surface) }

        let expectedContextValues = [
            "CMUX_WORKSPACE_ID": workspaceId.uuidString,
            "CMUX_SURFACE_ID": surface.id.uuidString,
            "CMUX_TAB_ID": workspaceId.uuidString,
            "CMUX_PANEL_ID": surface.id.uuidString,
        ]

        for (key, expectedValue) in expectedContextValues {
            let value = try #require(surface.startupEnvironmentValue(key), "\(key) should be present")
            expectFalse(value.isEmpty, "\(key) should be non-empty")
            expectEqual(value, expectedValue)
        }

        let socketPath = try #require(
            surface.startupEnvironmentValue("CMUX_SOCKET_PATH"),
            "CMUX_SOCKET_PATH should be present"
        )
        expectFalse(socketPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test
    func testApplyManagedTerminalIdentityEnvironmentOverridesInheritedValues() {
        var environment = [
            "TERM": "xterm-ghostty",
            "COLORTERM": "24bit",
            "TERM_PROGRAM": "Apple_Terminal",
            "CUSTOM_FLAG": "1",
        ]
        var protectedKeys: Set<String> = []

        TerminalSurface.applyManagedTerminalIdentityEnvironment(
            to: &environment,
            protectedKeys: &protectedKeys
        )

        expectEqual(environment["TERM"], TerminalSurface.managedTerminalType)
        expectEqual(environment["COLORTERM"], TerminalSurface.managedColorTerm)
        expectEqual(environment["TERM_PROGRAM"], TerminalSurface.managedTerminalProgram)
        expectEqual(environment["CUSTOM_FLAG"], "1")
        expectTrue(protectedKeys.contains("TERM"))
        expectTrue(protectedKeys.contains("COLORTERM"))
        expectTrue(protectedKeys.contains("TERM_PROGRAM"))
    }

    @Test
    func testApplyManagedGitWatchEnvironmentDisablesShellGitWatch() {
        var environment: [String: String] = [:]
        var protectedKeys: Set<String> = []

        TerminalSurface.applyManagedGitWatchEnvironment(
            watchGitStatusEnabled: false,
            to: &environment,
            protectedKeys: &protectedKeys
        )

        expectEqual(environment["CMUX_NO_GIT_WATCH"], "1")
        expectTrue(protectedKeys.contains("CMUX_NO_GIT_WATCH"))
    }

    @Test
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

        expectEqual(merged["CMUX_NO_GIT_WATCH"], "")
    }

    @Test
    func testApplyManagedGitWatchEnvironmentDisablesShellPullRequestWatchWhenHidden() {
        var environment = [
            "CMUX_NO_PR_WATCH": ""
        ]
        var protectedKeys: Set<String> = []

        TerminalSurface.applyManagedGitWatchEnvironment(
            watchGitStatusEnabled: true,
            showPullRequestsEnabled: false,
            to: &environment,
            protectedKeys: &protectedKeys
        )

        expectEqual(environment["CMUX_NO_GIT_WATCH"], "")
        expectEqual(environment["CMUX_NO_PR_WATCH"], "1")
        expectTrue(protectedKeys.contains("CMUX_NO_GIT_WATCH"))
        expectTrue(protectedKeys.contains("CMUX_NO_PR_WATCH"))
    }

    @Test
    func testPathByPrependingUniqueDirectoryMovesDirectoryToFront() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GhosttyTerminalStartupEnvironmentTests-\(UUID().uuidString)", isDirectory: true)
        let first = root.appendingPathComponent("first", isDirectory: true).standardizedFileURL.path
        let shim = root.appendingPathComponent("shim", isDirectory: true).standardizedFileURL.path
        let last = root.appendingPathComponent("last", isDirectory: true).standardizedFileURL.path

        let path = TerminalSurface.pathByPrependingUniqueDirectory(
            shim,
            to: [first, shim, last].joined(separator: ":")
        )

        expectEqual(path.split(separator: ":").map(String.init), [shim, first, last])
    }

    @Test
    func testPathByPrependingUniqueDirectoryPreservesEmptyComponents() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GhosttyTerminalStartupEnvironmentTests-\(UUID().uuidString)", isDirectory: true)
        let first = root.appendingPathComponent("first", isDirectory: true).standardizedFileURL.path
        let shim = root.appendingPathComponent("shim", isDirectory: true).standardizedFileURL.path
        let last = root.appendingPathComponent("last", isDirectory: true).standardizedFileURL.path

        let path = TerminalSurface.pathByPrependingUniqueDirectory(
            shim,
            to: ":\(first)::\(shim):\(last):"
        )

        expectEqual(
            path.split(separator: ":", omittingEmptySubsequences: false).map(String.init),
            [shim, "", first, "", last, ""]
        )
    }

    @Test
    func testPathByPrependingUniqueDirectoryDoesNotAppendCurrentDirectoryWhenPathIsEmpty() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GhosttyTerminalStartupEnvironmentTests-\(UUID().uuidString)", isDirectory: true)
        let shim = root.appendingPathComponent("shim", isDirectory: true).standardizedFileURL.path

        let emptyPath = TerminalSurface.pathByPrependingUniqueDirectory(shim, to: "")
        let whitespacePath = TerminalSurface.pathByPrependingUniqueDirectory(shim, to: "   ")

        expectEqual(emptyPath, shim)
        expectEqual(whitespacePath, shim)
        expectFalse(emptyPath.contains(":"))
        expectFalse(whitespacePath.contains(":"))
    }

    @Test
    func testInstallClaudeCommandShimCreatesExecutableOutsideBundleBin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GhosttyTerminalStartupEnvironmentTests-\(UUID().uuidString)", isDirectory: true)
        let bundleBin =
            root
            .appendingPathComponent("cmux.app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        let tempRoot = root.appendingPathComponent("tmp", isDirectory: true)
        let logURL = root.appendingPathComponent("shim.log", isDirectory: false)
        try FileManager.default.createDirectory(at: bundleBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let wrapperURL = bundleBin.appendingPathComponent("cmux-claude-wrapper", isDirectory: false)
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        {
            printf 'shim=%s\\n' "${CMUX_CLAUDE_WRAPPER_SHIM:-}"
            printf 'root=%s\\n' "${CMUX_CLAUDE_WRAPPER_SHIM_ROOT:-}"
            printf 'args=%s\\n' "$*"
        } > "$CMUX_TEST_LOG"
        """.write(to: wrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapperURL.path)

        let surfaceId = UUID()
        let shim = try #require(
            TerminalSurface.installClaudeCommandShimIfPossible(
                wrapperURL: wrapperURL,
                surfaceId: surfaceId,
                temporaryDirectory: tempRoot
            ))

        expectEqual(
            shim.directoryPath,
            tempRoot
                .appendingPathComponent("cmux-cli-shims", isDirectory: true)
                .appendingPathComponent(surfaceId.uuidString, isDirectory: true)
                .standardizedFileURL
                .path
        )
        expectEqual(URL(fileURLWithPath: shim.executablePath).lastPathComponent, "claude")
        expectFalse(shim.executablePath.contains("/Contents/Resources/bin/claude"))
        expectTrue(FileManager.default.isExecutableFile(atPath: shim.executablePath))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shim.executablePath)
        process.arguments = ["hello", "two words"]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "CMUX_TEST_LOG": logURL.path,
        ]
        try process.run()
        process.waitUntilExit()

        expectEqual(process.terminationStatus, 0)
        let output = try String(contentsOf: logURL, encoding: .utf8)
        expectTrue(output.contains("shim=\(shim.executablePath)\n"), output)
        expectTrue(output.contains("root=\(shim.directoryPath)\n"), output)
        expectTrue(output.contains("args=hello two words\n"), output)
    }

    @Test
    func testClaudeCommandShimFallsBackToCurrentBundledWrapperWhenEmbeddedWrapperWasReaped() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GhosttyTerminalStartupEnvironmentTests-\(UUID().uuidString)", isDirectory: true)
        let oldBundleBin =
            root
            .appendingPathComponent("old.app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        let currentBundleBin =
            root
            .appendingPathComponent("current.app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        let tempRoot = root.appendingPathComponent("tmp", isDirectory: true)
        let logURL = root.appendingPathComponent("shim.log", isDirectory: false)
        for directory in [oldBundleBin, currentBundleBin, tempRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        func writeExecutable(_ url: URL, _ body: String) throws {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        let staleWrapperURL = oldBundleBin.appendingPathComponent("cmux-claude-wrapper", isDirectory: false)
        try writeExecutable(staleWrapperURL, """
        #!/usr/bin/env bash
        printf 'stale %s\\n' "$*" > "$CMUX_TEST_LOG"
        """)

        let currentWrapperURL = currentBundleBin.appendingPathComponent("cmux-claude-wrapper", isDirectory: false)
        try writeExecutable(currentWrapperURL, """
        #!/usr/bin/env bash
        printf 'current %s\\n' "$*" > "$CMUX_TEST_LOG"
        """)
        let currentCLIURL = currentBundleBin.appendingPathComponent("cmux", isDirectory: false)
        try writeExecutable(currentCLIURL, """
        #!/usr/bin/env bash
        exit 0
        """)

        let shim = try #require(
            TerminalSurface.installClaudeCommandShimIfPossible(
                wrapperURL: staleWrapperURL,
                surfaceId: UUID(),
                temporaryDirectory: tempRoot
            ))
        try FileManager.default.removeItem(at: staleWrapperURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shim.executablePath)
        process.arguments = ["--resume", "session-id"]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "CMUX_BUNDLED_CLI_PATH": currentCLIURL.path,
            "CMUX_TEST_LOG": logURL.path,
        ]
        try process.run()
        process.waitUntilExit()

        expectEqual(process.terminationStatus, 0)
        let output = try String(contentsOf: logURL, encoding: .utf8)
        expectEqual(output, "current --resume session-id\n")
    }

    @Test
    func testClaudeCommandShimFallbackSkipsInheritedCmuxShimRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GhosttyTerminalStartupEnvironmentTests-\(UUID().uuidString)", isDirectory: true)
        let bundleBin =
            root
            .appendingPathComponent("cmux.app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        let tempRoot = root.appendingPathComponent("tmp", isDirectory: true)
        let oldShimRoot = tempRoot
            .appendingPathComponent("cmux-cli-shims", isDirectory: true)
            .appendingPathComponent("old-surface", isDirectory: true)
        let realBin = root.appendingPathComponent("real-bin", isDirectory: true)
        let logURL = root.appendingPathComponent("shim.log", isDirectory: false)
        for directory in [bundleBin, oldShimRoot, realBin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        func writeExecutable(_ url: URL, _ body: String) throws {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        let wrapperURL = bundleBin.appendingPathComponent("cmux-claude-wrapper", isDirectory: false)
        try writeExecutable(wrapperURL, """
        #!/usr/bin/env bash
        printf 'stale-wrapper %s\\n' "$*" > "$CMUX_TEST_LOG"
        """)
        let oldShimURL = oldShimRoot.appendingPathComponent("claude", isDirectory: false)
        try writeExecutable(oldShimURL, """
        #!/usr/bin/env bash
        printf 'old-shim %s\\n' "$*" > "$CMUX_TEST_LOG"
        exit 43
        """)
        let realClaudeURL = realBin.appendingPathComponent("claude", isDirectory: false)
        try writeExecutable(realClaudeURL, """
        #!/usr/bin/env bash
        printf 'real %s\\n' "$*" > "$CMUX_TEST_LOG"
        """)

        let shim = try #require(
            TerminalSurface.installClaudeCommandShimIfPossible(
                wrapperURL: wrapperURL,
                surfaceId: UUID(),
                temporaryDirectory: tempRoot
            ))
        try FileManager.default.removeItem(at: wrapperURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shim.executablePath)
        process.arguments = ["--resume", "session-id"]
        process.environment = [
            "PATH": "\(shim.directoryPath):\(oldShimRoot.path):\(realBin.path):/usr/bin:/bin",
            "CMUX_TEST_LOG": logURL.path,
        ]
        try process.run()
        process.waitUntilExit()

        expectEqual(process.terminationStatus, 0)
        let output = try String(contentsOf: logURL, encoding: .utf8)
        expectEqual(output, "real --resume session-id\n")
    }

    @Test
    func testMergedStartupEnvironmentAllowsSessionReplayAndInitialEnvCMUXKeys() {
        let replayPath = "/tmp/cmux-replay-\(UUID().uuidString)"
        let merged = TerminalSurface.mergedStartupEnvironment(
            base: [
                "PATH": "/usr/bin",
                "CMUX_SURFACE_ID": "managed-surface",
            ],
            protectedKeys: ["PATH", "CMUX_SURFACE_ID"],
            additionalEnvironment: [
                SessionScrollbackReplayStore.environmentKey: replayPath
            ],
            initialEnvironmentOverrides: [
                "CMUX_INITIAL_ENV_TOKEN": "token-123"
            ]
        )

        expectEqual(merged[SessionScrollbackReplayStore.environmentKey], replayPath)
        expectEqual(merged["CMUX_INITIAL_ENV_TOKEN"], "token-123")
    }

    @Test
    func testMergedStartupEnvironmentProtectsManagedKeysOnly() {
        let merged = TerminalSurface.mergedStartupEnvironment(
            base: [
                "PATH": "/usr/bin",
                "CMUX_SURFACE_ID": "managed-surface",
            ],
            protectedKeys: ["PATH", "CMUX_SURFACE_ID"],
            additionalEnvironment: [
                "CMUX_SURFACE_ID": "user-surface",
                "CUSTOM_FLAG": "1",
            ],
            initialEnvironmentOverrides: [
                "PATH": "/tmp/bin",
                "CMUX_SURFACE_ID": "override-surface",
            ]
        )

        expectEqual(merged["PATH"], "/usr/bin")
        expectEqual(merged["CMUX_SURFACE_ID"], "managed-surface")
        expectEqual(merged["CUSTOM_FLAG"], "1")
    }

    @Test
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
                "TERM_PROGRAM": "Apple_Terminal",
            ],
            initialEnvironmentOverrides: [
                "TERM": "screen-256color",
                "COLORTERM": "false",
                "TERM_PROGRAM": "WarpTerminal",
            ]
        )

        expectEqual(merged["TERM"], TerminalSurface.managedTerminalType)
        expectEqual(merged["COLORTERM"], TerminalSurface.managedColorTerm)
        expectEqual(merged["TERM_PROGRAM"], TerminalSurface.managedTerminalProgram)
    }

    @Test
    func testMergedStartupEnvironmentPreservesThirdPartyClaudeApiEnvironment() {
        let merged = TerminalSurface.mergedStartupEnvironment(
            base: [
                "CLAUDE_CONFIG_DIR": "/tmp/claude-config",
                "ANTHROPIC_API_KEY": "stale-api-key",
                "ANTHROPIC_AUTH_TOKEN": "third-party-auth-token",
                "ANTHROPIC_BASE_URL": "https://api.example.test",
                "ANTHROPIC_MODEL": "stale-model",
                "CUSTOM_FLAG": "1",
            ],
            protectedKeys: [],
            additionalEnvironment: [:],
            initialEnvironmentOverrides: [:]
        )

        expectEqual(merged["CLAUDE_CONFIG_DIR"], "/tmp/claude-config")
        expectEqual(merged["ANTHROPIC_API_KEY"], "")
        expectEqual(merged["ANTHROPIC_AUTH_TOKEN"], "third-party-auth-token")
        expectEqual(merged["ANTHROPIC_BASE_URL"], "https://api.example.test")
        expectEqual(merged["ANTHROPIC_MODEL"], "")
        expectEqual(merged["CUSTOM_FLAG"], "1")
    }

    @Test
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
                "ANTHROPIC_MODEL": "ambient-model",
            ]
        )

        expectNil(merged["CLAUDE_CONFIG_DIR"])
        expectEqual(merged["ANTHROPIC_API_KEY"], "")
        expectNil(merged["ANTHROPIC_AUTH_TOKEN"])
        expectNil(merged["ANTHROPIC_BASE_URL"])
        expectEqual(merged["ANTHROPIC_MODEL"], "")
        expectEqual(merged["CUSTOM_FLAG"], "1")
    }

    @Test
    func testMergedStartupEnvironmentAllowsExplicitClaudeAuthSelectionOverrides() {
        let merged = TerminalSurface.mergedStartupEnvironment(
            base: [
                "CLAUDE_CONFIG_DIR": "/tmp/stale-claude-config",
                "ANTHROPIC_API_KEY": "stale-api-key",
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

        expectEqual(merged["CLAUDE_CONFIG_DIR"], "/tmp/resume-claude-config")
        expectEqual(merged["ANTHROPIC_API_KEY"], "explicit-api-key")
        expectEqual(merged["ANTHROPIC_MODEL"], "")
    }

    @Test
    func testMergedStartupEnvironmentDoesNotDeriveHermesCodexBaseURLForGenericTerminals() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hermes-codex-startup-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try """
        openai_base_url = "http://subrouter-team:31415/v1"
        chatgpt_base_url = "http://subrouter-team:31415/backend-api"
        """.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let merged = TerminalSurface.mergedStartupEnvironment(
            base: [
                "CODEX_HOME": codexHome.path
            ],
            protectedKeys: [],
            additionalEnvironment: [:],
            initialEnvironmentOverrides: [:],
            ambientEnvironment: [:]
        )

        expectNil(merged["HERMES_CODEX_BASE_URL"])
        expectNil(merged["CUSTOM_BASE_URL"])
    }

    @Test
    func testMergedStartupEnvironmentDerivesHermesCodexBaseURLWhenRequested() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hermes-codex-startup-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try """
        openai_base_url = "http://subrouter-team:31415/v1"
        chatgpt_base_url = "http://subrouter-team:31415/backend-api"
        """.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let merged = TerminalSurface.mergedStartupEnvironment(
            base: [
                "CODEX_HOME": codexHome.path
            ],
            protectedKeys: [],
            additionalEnvironment: [:],
            initialEnvironmentOverrides: [:],
            ambientEnvironment: [:],
            applyHermesCodexDefaults: true
        )

        expectEqual(
            merged["HERMES_CODEX_BASE_URL"],
            "http://subrouter-team:31415/backend-api/codex"
        )
        expectEqual(
            merged["CUSTOM_BASE_URL"],
            "http://subrouter-team:31415/v1"
        )
    }
}
