import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RestorableAgentSessionIndexTests: XCTestCase {
    func testClaudeHookSnapshotRequiresTranscriptFile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-claude-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: projectsDir.appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path),
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )

        let validSessionId = "11111111-1111-1111-1111-111111111111"
        let missingSessionId = "22222222-2222-2222-2222-222222222222"
        let startupOnlyWithTranscriptSessionId = "33333333-3333-3333-3333-333333333333"
        let startupOnlyMissingSessionId = "44444444-4444-4444-4444-444444444444"
        let explicitTranscriptSessionId = "55555555-5555-5555-5555-555555555555"
        let validWorkspaceId = UUID()
        let validPanelId = UUID()
        let missingWorkspaceId = UUID()
        let missingPanelId = UUID()
        let startupOnlyWithTranscriptWorkspaceId = UUID()
        let startupOnlyWithTranscriptPanelId = UUID()
        let startupOnlyMissingWorkspaceId = UUID()
        let startupOnlyMissingPanelId = UUID()
        let explicitTranscriptWorkspaceId = UUID()
        let explicitTranscriptPanelId = UUID()

        try writeClaudeTranscript(sessionId: validSessionId, cwd: cwd, projectsDir: projectsDir)
        try writeClaudeTranscript(sessionId: startupOnlyWithTranscriptSessionId, cwd: cwd, projectsDir: projectsDir)
        let explicitTranscriptURL = root
            .appendingPathComponent("other-transcripts", isDirectory: true)
            .appendingPathComponent("\(explicitTranscriptSessionId).jsonl", isDirectory: false)
        try fm.createDirectory(
            at: explicitTranscriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeClaudeTranscript(sessionId: explicitTranscriptSessionId, transcriptURL: explicitTranscriptURL, cwd: cwd)

        try writeClaudeHookStore(
            root: root,
            sessions: [
                validSessionId: hookRecord(
                    sessionId: validSessionId,
                    workspaceId: validWorkspaceId,
                    panelId: validPanelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    updatedAt: 20
                ),
                missingSessionId: hookRecord(
                    sessionId: missingSessionId,
                    workspaceId: missingWorkspaceId,
                    panelId: missingPanelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    updatedAt: 30
                ),
                startupOnlyWithTranscriptSessionId: hookRecord(
                    sessionId: startupOnlyWithTranscriptSessionId,
                    workspaceId: startupOnlyWithTranscriptWorkspaceId,
                    panelId: startupOnlyWithTranscriptPanelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    isRestorable: false,
                    updatedAt: 40
                ),
                startupOnlyMissingSessionId: hookRecord(
                    sessionId: startupOnlyMissingSessionId,
                    workspaceId: startupOnlyMissingWorkspaceId,
                    panelId: startupOnlyMissingPanelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    isRestorable: false,
                    updatedAt: 50
                ),
                explicitTranscriptSessionId: hookRecord(
                    sessionId: explicitTranscriptSessionId,
                    workspaceId: explicitTranscriptWorkspaceId,
                    panelId: explicitTranscriptPanelId,
                    cwd: root.appendingPathComponent("different-cwd", isDirectory: true).path,
                    configDir: root.appendingPathComponent("different-config", isDirectory: true).path,
                    transcriptPath: explicitTranscriptURL.path,
                    isRestorable: false,
                    updatedAt: 60
                ),
            ]
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fm
        )

        XCTAssertEqual(
            index.snapshot(workspaceId: validWorkspaceId, panelId: validPanelId)?.sessionId,
            validSessionId
        )
        XCTAssertNil(
            index.snapshot(workspaceId: missingWorkspaceId, panelId: missingPanelId),
            "A Claude SessionStart without a transcript file must not be auto-restored because Claude cannot resume it."
        )
        XCTAssertEqual(
            index.snapshot(
                workspaceId: startupOnlyWithTranscriptWorkspaceId,
                panelId: startupOnlyWithTranscriptPanelId
            )?.sessionId,
            startupOnlyWithTranscriptSessionId,
            "A transcript-backed Claude session remains restorable even before a new turn is observed in this process."
        )
        XCTAssertNil(
            index.snapshot(workspaceId: startupOnlyMissingWorkspaceId, panelId: startupOnlyMissingPanelId),
            "A startup-only Claude hook record without a transcript must stay non-restorable."
        )
        XCTAssertEqual(
            index.snapshot(workspaceId: explicitTranscriptWorkspaceId, panelId: explicitTranscriptPanelId)?.sessionId,
            explicitTranscriptSessionId,
            "When Claude provides transcript_path, restore eligibility should use that exact file before reconstructing from cwd."
        )
    }

    func testClaudeForkCommandUsesTranscriptProjectWorkingDirectoryWhenHookCwdDrifts() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-claude-fork-cwd-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let projectCwd = root.appendingPathComponent("cmuxterm-hq", isDirectory: true)
        let hookCwd = projectCwd
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("feat-ios-swift-mobile-core", isDirectory: true)
        try fm.createDirectory(at: hookCwd, withIntermediateDirectories: true)

        let sessionId = "11111111-2222-3333-4444-555555555555"
        let transcriptURL = projectsDir
            .appendingPathComponent(RestorableAgentSessionIndex.encodeClaudeProjectDir(projectCwd.path), isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: transcriptURL, cwd: projectCwd)

        let workspaceId = UUID()
        let panelId = UUID()
        try writeClaudeHookStore(
            root: root,
            sessions: [
                sessionId: hookRecord(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    cwd: hookCwd.path,
                    configDir: configDir.path,
                    transcriptPath: transcriptURL.path,
                    isRestorable: nil,
                    updatedAt: 20,
                    launchWorkingDirectory: projectCwd.path
                ),
            ]
        )

        let snapshot = try XCTUnwrap(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                .snapshot(workspaceId: workspaceId, panelId: panelId)
        )

        XCTAssertEqual(snapshot.workingDirectory, hookCwd.path)
        XCTAssertEqual(
            snapshot.forkCommand,
            "{ cd -- '\(projectCwd.path)' 2>/dev/null || [ ! -d '\(projectCwd.path)' ]; } && 'env' 'CLAUDE_CONFIG_DIR=\(configDir.path)' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1' 'CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=CLAUDE_CONFIG_DIR' '/usr/local/bin/claude' '--resume' '\(sessionId)' '--fork-session' '--dangerously-skip-permissions'"
        )
        XCTAssertFalse(
            snapshot.forkCommand?.contains("{ cd -- '\(hookCwd.path)'") ?? false,
            "Claude must fork from the transcript project directory, not the later hook cwd, or Claude cannot find the conversation."
        )
    }

    func testClaudeForkCommandDoesNotLossilyDecodeHyphenatedTranscriptProjectDirectory() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "cmuxclaudehyphen\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                isDirectory: true
            )
        defer { try? fm.removeItem(at: root) }

        let projectCwd = root.appendingPathComponent("my-project", isDirectory: true)
        let hookCwd = root.appendingPathComponent("drifted-cwd", isDirectory: true)
        try fm.createDirectory(at: projectCwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: hookCwd, withIntermediateDirectories: true)

        let sessionId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let encodedProjectDir = RestorableAgentSessionIndex.encodeClaudeProjectDir(projectCwd.path)
        let transcriptURL = root
            .appendingPathComponent("claude-config", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encodedProjectDir, isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)

        let lossyDecodedPath = "/" + String(encodedProjectDir.dropFirst())
            .replacingOccurrences(of: "-", with: "/")
        try fm.createDirectory(
            at: URL(fileURLWithPath: lossyDecodedPath, isDirectory: true),
            withIntermediateDirectories: true
        )

        let command = AgentResumeCommandBuilder.forkShellCommand(
            kind: .claude,
            sessionId: sessionId,
            launchCommand: nil,
            workingDirectory: hookCwd.path,
            transcriptPath: transcriptURL.path
        )

        XCTAssertEqual(
            command,
            "{ cd -- '\(hookCwd.path)' 2>/dev/null || [ ! -d '\(hookCwd.path)' ]; } && 'claude' '--resume' '\(sessionId)' '--fork-session'"
        )
        XCTAssertFalse(
            command?.contains("{ cd -- '\(lossyDecodedPath)'") ?? false,
            "Claude transcript project directory names cannot be decoded by replacing every hyphen with a slash."
        )
    }

    func testPanelFallbackUsesLatestHookRecord() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-claude-panel-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: projectsDir.appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path),
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )

        let panelId = UUID()
        let oldWorkspaceId = UUID()
        let latestWorkspaceId = UUID()
        let movedWorkspaceId = UUID()
        let oldSessionId = "11111111-1111-1111-1111-111111111111"
        let latestSessionId = "22222222-2222-2222-2222-222222222222"
        try writeClaudeTranscript(sessionId: oldSessionId, cwd: cwd, projectsDir: projectsDir)
        try writeClaudeTranscript(sessionId: latestSessionId, cwd: cwd, projectsDir: projectsDir)

        try writeClaudeHookStore(
            root: root,
            sessions: [
                oldSessionId: hookRecord(
                    sessionId: oldSessionId,
                    workspaceId: oldWorkspaceId,
                    panelId: panelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    updatedAt: 10
                ),
                latestSessionId: hookRecord(
                    sessionId: latestSessionId,
                    workspaceId: latestWorkspaceId,
                    panelId: panelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    updatedAt: 20
                ),
            ]
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fm
        )

        XCTAssertEqual(
            index.snapshot(workspaceId: oldWorkspaceId, panelId: panelId)?.sessionId,
            oldSessionId
        )
        XCTAssertEqual(
            index.snapshot(workspaceId: movedWorkspaceId, panelId: panelId)?.sessionId,
            latestSessionId
        )
    }

    private func hookRecord(
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        cwd: String,
        configDir: String,
        updatedAt: TimeInterval
    ) -> [String: Any] {
        hookRecord(
            sessionId: sessionId,
            workspaceId: workspaceId,
            panelId: panelId,
            cwd: cwd,
            configDir: configDir,
            isRestorable: nil,
            updatedAt: updatedAt
        )
    }

    private func hookRecord(
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        cwd: String,
        configDir: String,
        isRestorable: Bool?,
        updatedAt: TimeInterval
    ) -> [String: Any] {
        hookRecord(
            sessionId: sessionId,
            workspaceId: workspaceId,
            panelId: panelId,
            cwd: cwd,
            configDir: configDir,
            transcriptPath: nil,
            isRestorable: isRestorable,
            updatedAt: updatedAt
        )
    }

    private func hookRecord(
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        cwd: String,
        configDir: String,
        transcriptPath: String?,
        isRestorable: Bool?,
        updatedAt: TimeInterval,
        launchWorkingDirectory: String? = nil
    ) -> [String: Any] {
        var record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": cwd,
            "pid": NSNull(),
            "updatedAt": updatedAt,
            "launchCommand": [
                "launcher": "claude",
                "executablePath": "/usr/local/bin/claude",
                "arguments": ["/usr/local/bin/claude", "--dangerously-skip-permissions"],
                "workingDirectory": launchWorkingDirectory ?? cwd,
                "environment": ["CLAUDE_CONFIG_DIR": configDir],
                "capturedAt": updatedAt,
                "source": "test",
            ],
        ]
        if let isRestorable {
            record["isRestorable"] = isRestorable
        }
        if let transcriptPath {
            record["transcriptPath"] = transcriptPath
        }
        return record
    }

    private func writeClaudeTranscript(sessionId: String, cwd: URL, projectsDir: URL) throws {
        let transcriptURL = projectsDir
            .appendingPathComponent(RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path), isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: transcriptURL, cwd: cwd)
    }

    private func writeClaudeTranscript(sessionId: String, transcriptURL: URL, cwd: URL) throws {
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"last-prompt","sessionId":"\(sessionId)"}
        {"type":"user","sessionId":"\(sessionId)","cwd":"\(cwd.path)","message":{"role":"user","content":"hello"}}

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
        try data.write(
            to: stateDir.appendingPathComponent("claude-hook-sessions.json", isDirectory: false),
            options: .atomic
        )
    }
}
