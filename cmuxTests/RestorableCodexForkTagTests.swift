import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct RestorableCodexForkTagTests {
    @Test
    func testRestoredBareCodexResumeRoutesThroughPortableWrapperRenderer() throws {
        let command = try #require(
            AgentResumeCommandBuilder().resumeShellCommand(
                kind: .codex,
                sessionId: "codex-session-123",
                launchCommand: codexLaunchCommand(
                    executablePath: nil,
                    arguments: ["codex", "--model", "gpt-5"]
                ),
                workingDirectory: nil,
                includeWorkingDirectoryPrefix: false
            )
        )
        let expected = AgentResumeArgv.renderedPortableCodexResumeShellCommand(
            parts: [
                "codex",
                "resume",
                "codex-session-123",
                "-c",
                "check_for_update_on_startup=false",
                "--model",
                "gpt-5",
            ],
            quote: TerminalStartupShellQuoting().singleQuoted
        )

        #expect(command == expected)
        #expect(command.hasPrefix("/bin/sh -c "))
        #expect(command.contains("CMUX_CODEX_WRAPPER_SHIM"))
    }

    @Test
    func testRestoredBareCodexForkRoutesThroughPortableWrapperRendererAndDropsStaleForkSession() throws {
        let command = try #require(
            AgentResumeCommandBuilder().forkShellCommand(
                kind: .codex,
                sessionId: "codex-child-session",
                launchCommand: codexLaunchCommand(
                    executablePath: nil,
                    arguments: [
                        "codex",
                        "fork",
                        "stale-parent-session",
                        "tag-one",
                        "--sandbox",
                        "danger-full-access",
                    ]
                ),
                workingDirectory: nil,
                includeWorkingDirectoryPrefix: false
            )
        )
        let expected = AgentResumeArgv.renderedPortableCodexResumeShellCommand(
            parts: [
                "codex",
                "fork",
                "codex-child-session",
                "tag-one",
                "--sandbox",
                "danger-full-access",
            ],
            quote: TerminalStartupShellQuoting().singleQuoted
        )

        #expect(command == expected)
        #expect(command.hasPrefix("/bin/sh -c "))
        #expect(command.contains("CMUX_CODEX_WRAPPER_SHIM"))
        #expect(!command.contains("stale-parent-session"))
    }

    @Test
    func testRestoredCodexTeamsForkDropsStaleForkSession() throws {
        let command = try #require(
            AgentResumeCommandBuilder().forkShellCommand(
                kind: .codex,
                sessionId: "codex-child-session",
                launchCommand: codexLaunchCommand(
                    launcher: "codexTeams",
                    executablePath: nil,
                    arguments: [
                        "cmux",
                        "codex-teams",
                        "fork",
                        "stale-parent-session",
                        "tag-one",
                        "--model",
                        "gpt-5",
                    ]
                ),
                workingDirectory: nil,
                includeWorkingDirectoryPrefix: false
            )
        )

        #expect(command == "'cmux' 'codex-teams' 'fork' 'codex-child-session' 'tag-one' '--model' 'gpt-5'")
        #expect(!command.hasPrefix("/bin/sh -c "))
        #expect(!command.contains("stale-parent-session"))
    }

    @Test
    func testRestoredCodexForkPreservesPromptTagsWhenForkedAgain() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-codex-fork-tags-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dir = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "019ef275-74e3-7777-9773-9dcb118ed5ad"
        try writeHookStore(
            root: root,
            sessions: [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": dir.path,
                    "pid": NSNull(),
                    "isRestorable": true,
                    "updatedAt": 10,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": [
                            "/usr/local/bin/codex",
                            "fork",
                            "019ef275-74e3-7777-9773-9dcb118ed5ac",
                            "tag-one",
                            "tag two",
                            "--model",
                            "gpt-5",
                        ],
                        "workingDirectory": dir.path,
                        "capturedAt": 10,
                        "source": "environment",
                    ],
                ],
            ]
        )

        let snapshot = try #require(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                .snapshot(workspaceId: workspaceId, panelId: panelId)
        )
        let fork = try #require(snapshot.forkCommand)
        #expect(
            fork.contains("'fork' '\(sessionId)' 'tag-one' 'tag two' '--model' 'gpt-5'"),
            Comment(rawValue: "forking a restored forked session must preserve every prompt tag; got: \(fork)")
        )
    }

    private func writeHookStore(root: URL, sessions: [String: [String: Any]]) throws {
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "sessions": sessions],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
    }

    private func codexLaunchCommand(
        launcher: String = "codex",
        executablePath: String?,
        arguments: [String]
    ) -> AgentLaunchCommandSnapshot {
        AgentLaunchCommandSnapshot(
            launcher: launcher,
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: nil,
            environment: nil,
            capturedAt: nil,
            source: "test"
        )
    }
}
