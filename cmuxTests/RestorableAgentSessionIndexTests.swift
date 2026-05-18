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
        updatedAt: TimeInterval
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
                "workingDirectory": cwd,
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
