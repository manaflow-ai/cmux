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
        XCTAssertNil(ClaudeConfigurationRoot.configuredResumeDirectory(root.appendingPathComponent(".claude").path))

        let command = try XCTUnwrap(
            makeClaudeSessionEntry(fileURL: transcriptURL).copyResumeCommand
        )

        XCTAssertFalse(command.contains("CLAUDE_CONFIG_DIR="))
        XCTAssertTrue(command.hasPrefix("cd -- '/tmp/repo' 2>/dev/null || [ ! -d '/tmp/repo' ] && "))
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
            XCTAssertNil(ClaudeConfigurationRoot.configuredResumeDirectory(configDir.path))
        }

        try Data(#"{"primaryApiKey":"sk-ant-api03-example"}"#.utf8).write(to: stateURL)
        XCTAssertEqual(ClaudeConfigurationRoot.configuredResumeDirectory(configDir.path), configDir.path)
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
        let resumeConfigDir = try XCTUnwrap(ClaudeConfigurationRoot.configuredResumeDirectory(configDir.path))

        let command = try XCTUnwrap(
            makeClaudeSessionEntry(
                fileURL: transcriptURL,
                configDirectoryForResume: resumeConfigDir
            ).copyResumeCommand
        )

        XCTAssertTrue(command.contains("CLAUDE_CONFIG_DIR=\(configDir.path)"))
        XCTAssertTrue(command.contains(
            AgentResumeArgv.claudeWrapperShellExecutableToken
                .replacingOccurrences(of: "'", with: "'\\''") + " --resume session-123"
        ))
    }

    func testClaudeSessionRootsIncludeSignedInSiblingAccountDirectories() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-sibling-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        func makeConfigDir(_ name: String, projects: Bool, state: String?) throws -> URL {
            let dir = home.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if projects {
                try FileManager.default.createDirectory(
                    at: dir.appendingPathComponent("projects", isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            if let state {
                try Data(state.utf8).write(to: dir.appendingPathComponent(".claude.json", isDirectory: false))
            }
            return dir
        }

        let signedIn = #"{"oauthAccount":{"email":"user@example.com"}}"#
        let primary = try makeConfigDir(".claude", projects: true, state: nil)
        let work = try makeConfigDir(".claude-work", projects: true, state: signedIn)
        _ = try makeConfigDir(".claude-signed-out", projects: true, state: #"{"oauthAccount":null}"#)
        _ = try makeConfigDir(".claude-no-projects", projects: false, state: signedIn)
        _ = try makeConfigDir("claude-not-hidden", projects: true, state: signedIn)

        let roots = SessionIndexStore.claudeSessionRoots(
            environment: [:],
            homeDirectory: home.path
        )

        XCTAssertEqual(roots.map(\.configDir), [primary.path, work.path])
        XCTAssertEqual(roots.last?.resumeConfigDirectory, work.path)
    }

    func testClaudeSessionRootsDoNotDuplicateSiblingSelectedByEnvironment() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-sibling-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let work = home.appendingPathComponent(".claude-work", isDirectory: true)
        try FileManager.default.createDirectory(
            at: work.appendingPathComponent("projects", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(#"{"oauthAccount":{"email":"user@example.com"}}"#.utf8)
            .write(to: work.appendingPathComponent(".claude.json", isDirectory: false))

        let roots = SessionIndexStore.claudeSessionRoots(
            environment: ["CLAUDE_CONFIG_DIR": work.path],
            homeDirectory: home.path
        )

        XCTAssertEqual(roots.map(\.configDir), [work.path])
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
