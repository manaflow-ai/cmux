import CMUXAgentLaunch
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ClaudeConfigDirectoryPathTests: XCTestCase {
    func testPrefersCodexAccountsAliasForSubrouterPath() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-config-home-\(UUID().uuidString)", isDirectory: true)
        let legacyConfig = home
            .appendingPathComponent(".subrouter", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: true)
            .appendingPathComponent("_p1775010019397", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyConfig, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".codex-accounts", isDirectory: true),
            withDestinationURL: home.appendingPathComponent(".subrouter", isDirectory: true)
                .appendingPathComponent("codex", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let preferred = ClaudeConfigDirectoryPath.preferredPath(
            legacyConfig.path,
            homeDirectory: home.path
        )

        XCTAssertEqual(
            preferred,
            home
                .appendingPathComponent(".codex-accounts", isDirectory: true)
                .appendingPathComponent("claude", isDirectory: true)
                .appendingPathComponent("_p1775010019397", isDirectory: true)
                .path
        )
    }

    func testClaudeResumeCommandOmitsUnconfiguredCanonicalConfigDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcriptURL = root
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-tmp-repo", isDirectory: true)
            .appendingPathComponent("session-123.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertNil(ClaudeConfigurationProbe().configuredResumeDirectory(root.appendingPathComponent(".claude").path))

        let command = try XCTUnwrap(
            makeClaudeSessionEntry(fileURL: transcriptURL).resumeCommand
        )

        XCTAssertFalse(command.contains("CLAUDE_CONFIG_DIR="))
        XCTAssertTrue(command.hasPrefix("cd /tmp/repo && "))
        XCTAssertTrue(command.contains(
            AgentResumeArgv.claudeWrapperShellExecutableToken
                .replacingOccurrences(of: "'", with: "'\\''") + " --resume session-123"
        ))
        XCTAssertTrue(command.contains("--model claude-opus-4-7"))
        XCTAssertTrue(command.contains("--permission-mode default"))
    }

    func testConfiguredResumeDirectoryIgnoresNullAndEmptyAuthFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-config-state-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent(".claude", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let stateURL = configDir.appendingPathComponent(".claude.json", isDirectory: false)

        for payload in [
            #"{"oauthAccount":null,"primaryApiKey":null,"apiKey":null}"#,
            #"{"oauthAccount":{},"primaryApiKey":"","apiKey":"   "}"#,
            #"{"oauthAccount":[],"primaryApiKey":"\n\t","apiKey":""}"#
        ] {
            try Data(payload.utf8).write(to: stateURL)
            XCTAssertNil(ClaudeConfigurationProbe().configuredResumeDirectory(configDir.path))
        }

        try Data(#"{"primaryApiKey":"sk-ant-api03-example"}"#.utf8).write(to: stateURL)
        XCTAssertEqual(ClaudeConfigurationProbe().configuredResumeDirectory(configDir.path), configDir.path)
    }

    func testClaudeResumeCommandPreservesConfiguredNonDefaultRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-account", isDirectory: true)
        let transcriptURL = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-tmp-repo", isDirectory: true)
            .appendingPathComponent("session-123.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stateURL = configDir.appendingPathComponent(".claude.json", isDirectory: false)
        try Data(#"{"oauthAccount":{"email":"user@example.com"}}"#.utf8)
            .write(to: stateURL)
        let resumeConfigDir = try XCTUnwrap(ClaudeConfigurationProbe().configuredResumeDirectory(configDir.path))

        let command = try XCTUnwrap(
            makeClaudeSessionEntry(
                fileURL: transcriptURL,
                configDirectoryForResume: resumeConfigDir
            ).resumeCommand
        )

        XCTAssertTrue(command.contains("CLAUDE_CONFIG_DIR=\(configDir.path)"))
        XCTAssertTrue(command.contains(
            AgentResumeArgv.claudeWrapperShellExecutableToken
                .replacingOccurrences(of: "'", with: "'\\''") + " --resume session-123"
        ))
    }

    private func makeClaudeSessionEntry(
        fileURL: URL,
        configDirectoryForResume: String? = nil
    ) -> SessionEntry {
        SessionEntry(
            id: "claude-session-123",
            agent: .claude,
            sessionId: "session-123",
            title: "Resume me",
            cwd: "/tmp/repo",
            gitBranch: nil,
            pullRequest: nil,
            modified: .now,
            fileURL: fileURL,
            specifics: .claude(
                model: "claude-opus-4-7",
                permissionMode: "default",
                configDirectoryForResume: configDirectoryForResume
            )
        )
    }
}
