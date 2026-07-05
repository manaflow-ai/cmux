import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct RestorableAgentLaunchTrustTests {
    @Test func shellWrapperArgvRejectionKeepsClaudeLaunchEnvironment() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-claude-shell-wrapper-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let launchCwd = root.appendingPathComponent("repo", isDirectory: true)
        let runtimeCwd = root.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: launchCwd, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeCwd, withIntermediateDirectories: true)

        let sessionId = "fd9fa480-0ae7-4ad1-9660-f1e124856d6d"
        let transcriptURL = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(claudeProjectDirName(launchCwd.path), isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: transcriptURL)

        let workspaceId = UUID()
        let panelId = UUID()
        try writeClaudeHookStore(
            root: root,
            sessions: [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": runtimeCwd.path,
                    "pid": NSNull(),
                    "isRestorable": true,
                    "transcriptPath": transcriptURL.path,
                    "updatedAt": 10,
                    "launchCommand": [
                        "launcher": "claude",
                        "executablePath": "bash",
                        "arguments": ["bash", "--noprofile", "--norc"],
                        "workingDirectory": launchCwd.path,
                        "environment": [
                            "ANTHROPIC_MODEL": "claude-sonnet-4-5",
                            "CLAUDE_CONFIG_DIR": configDir.path,
                        ],
                        "capturedAt": 10,
                        "source": "process",
                    ],
                ],
            ]
        )

        let snapshot = try #require(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fileManager)
                .snapshot(workspaceId: workspaceId, panelId: panelId)
        )
        let command = try #require(snapshot.resumeCommand)

        #expect(command.contains("cd -- '\(launchCwd.path)'"), Comment(rawValue: command))
        #expect(command.contains("ANTHROPIC_MODEL=claude-sonnet-4-5"), Comment(rawValue: command))
        #expect(command.contains("CLAUDE_CONFIG_DIR=\(configDir.path)"), Comment(rawValue: command))
        #expect(command.contains("CMUX_CLAUDE_WRAPPER_SHIM"), Comment(rawValue: command))
        #expect(!command.contains("'bash'"), Comment(rawValue: command))
        #expect(!command.contains("--noprofile"), Comment(rawValue: command))
        #expect(!command.contains(runtimeCwd.path), Comment(rawValue: command))
    }

    private func claudeProjectDirName(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func writeClaudeTranscript(sessionId: String, transcriptURL: URL) throws {
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"last-prompt","sessionId":"\(sessionId)"}

        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    private func writeClaudeHookStore(root: URL, sessions: [String: [String: Any]]) throws {
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": sessions,
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: stateDir.appendingPathComponent("claude-hook-sessions.json"))
    }
}
