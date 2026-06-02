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

    // A Claude session can start in one directory and `cd` into another (e.g. a repo root then a
    // worktree); the hook-reported `cwd` drifts to the latter, but Claude keeps the transcript in
    // the start directory's project folder. Fork/resume must cd into the directory that actually
    // holds the transcript, otherwise `claude --resume` fails with "No conversation found".
    //
    // The launch path contains a "." so this also exercises encodeClaudeProjectDir's "." -> "-"
    // contract, and the on-disk fixture is placed using a project-dir name computed independently of
    // the production helper so a regression in that helper fails the test instead of being masked.
    func testClaudeForkResolvesDriftedCwdViaTranscriptPath() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-claude-fork-drift-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let launchCwd = root.appendingPathComponent("repo.main", isDirectory: true)
        let driftedCwd = root.appendingPathComponent("worktree", isDirectory: true)
        try fm.createDirectory(at: launchCwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: driftedCwd, withIntermediateDirectories: true)
        let projectDir = projectsDir.appendingPathComponent(
            expectedClaudeProjectDirName(launchCwd.path),
            isDirectory: true
        )
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let sessionId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let workspaceId = UUID()
        let panelId = UUID()
        let transcriptURL = projectDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: transcriptURL, cwd: launchCwd)

        try writeClaudeHookStore(
            root: root,
            sessions: [
                sessionId: driftedHookRecord(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    recordedCwd: driftedCwd.path,
                    launchCwd: launchCwd.path,
                    configDir: configDir.path,
                    transcriptPath: transcriptURL.path,
                    updatedAt: 10
                ),
            ]
        )

        let index = RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspaceId, panelId: panelId))

        XCTAssertEqual(snapshot.workingDirectory, launchCwd.path)
        let forkCommand = try XCTUnwrap(snapshot.forkCommand)
        XCTAssertTrue(
            forkCommand.contains("cd -- '\(launchCwd.path)'"),
            "fork should cd into the transcript's directory; got: \(forkCommand)"
        )
        XCTAssertFalse(
            forkCommand.contains(driftedCwd.path),
            "fork must not cd into the drifted cwd; got: \(forkCommand)"
        )
    }

    // Same drift, but the record carries no explicit transcriptPath: resolution must still find the
    // correct directory by probing the Claude config directory on disk.
    func testClaudeForkResolvesDriftedCwdViaConfigScanWhenTranscriptPathMissing() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-claude-fork-drift-scan-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let launchCwd = root.appendingPathComponent("repo.main", isDirectory: true)
        let driftedCwd = root.appendingPathComponent("worktree", isDirectory: true)
        try fm.createDirectory(at: launchCwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: driftedCwd, withIntermediateDirectories: true)
        let projectDir = projectsDir.appendingPathComponent(
            expectedClaudeProjectDirName(launchCwd.path),
            isDirectory: true
        )
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let sessionId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let workspaceId = UUID()
        let panelId = UUID()
        let transcriptURL = projectDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: transcriptURL, cwd: launchCwd)

        try writeClaudeHookStore(
            root: root,
            sessions: [
                sessionId: driftedHookRecord(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    recordedCwd: driftedCwd.path,
                    launchCwd: launchCwd.path,
                    configDir: configDir.path,
                    transcriptPath: nil,
                    updatedAt: 10
                ),
            ]
        )

        let index = RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspaceId, panelId: panelId))

        XCTAssertEqual(snapshot.workingDirectory, launchCwd.path)
    }

    /// Mirrors Claude's external project-directory naming rule ("/" and "." both become "-")
    /// independently of the production `encodeClaudeProjectDir`, so these regression tests fail if
    /// that helper regresses instead of masking it by sharing the same code path.
    // When CMUX passes --session-id <uuid> to Claude and Claude uses the Workflow tool, Claude
    // creates <uuid>/ (a directory) as the Workflow container rather than <uuid>.jsonl. The actual
    // interactive transcript lands as a sibling file with a different UUID in the same project dir.
    // CMUX must detect the directory case and use the sibling's session ID for resume.
    func testClaudeWorkflowContainerUsesInteractiveSiblingTranscript() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-claude-workflow-sibling-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        let projectDir = projectsDir.appendingPathComponent(
            expectedClaudeProjectDirName(cwd.path),
            isDirectory: true
        )
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // UUID CMUX stored (passed as --session-id; Claude used it for the Workflow directory)
        let workflowContainerId = "a5323ac1-b493-46d1-a031-5549577d8bf8"
        // UUID of the actual interactive transcript Claude created internally
        let interactiveId = "18fc1ee3-0000-0000-0000-000000000000"
        let workspaceId = UUID()
        let panelId = UUID()

        // Workflow container directory with subagent artifacts inside
        let workflowDir = projectDir.appendingPathComponent(workflowContainerId, isDirectory: true)
        try fm.createDirectory(
            at: workflowDir.appendingPathComponent("subagents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "subagent data".write(
            to: workflowDir.appendingPathComponent("subagents/agent-0001.jsonl"),
            atomically: true, encoding: .utf8
        )

        // Actual interactive transcript — sibling of the Workflow directory
        try writeClaudeTranscript(
            sessionId: interactiveId,
            transcriptURL: projectDir.appendingPathComponent("\(interactiveId).jsonl"),
            cwd: cwd
        )

        try writeClaudeHookStore(
            root: root,
            sessions: [
                workflowContainerId: hookRecord(
                    sessionId: workflowContainerId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    updatedAt: 10
                ),
            ]
        )

        let index = RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
        XCTAssertEqual(
            index.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId,
            interactiveId,
            "Workflow container directory: must resolve to the interactive sibling transcript for resume."
        )
    }

    // When the stored session ID is a Workflow container directory but there is no sibling .jsonl,
    // the session cannot be resumed.
    func testClaudeWorkflowContainerWithNoSiblingIsNotRestorable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-claude-workflow-no-sibling-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        let projectDir = projectsDir.appendingPathComponent(
            expectedClaudeProjectDirName(cwd.path),
            isDirectory: true
        )
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let workflowContainerId = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        let workspaceId = UUID()
        let panelId = UUID()

        // Only the Workflow container directory, no sibling .jsonl
        try fm.createDirectory(
            at: projectDir.appendingPathComponent(workflowContainerId, isDirectory: true),
            withIntermediateDirectories: true
        )

        try writeClaudeHookStore(
            root: root,
            sessions: [
                workflowContainerId: hookRecord(
                    sessionId: workflowContainerId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    updatedAt: 10
                ),
            ]
        )

        let index = RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
        XCTAssertNil(
            index.snapshot(workspaceId: workspaceId, panelId: panelId),
            "Workflow container directory without a sibling transcript must not be restorable."
        )
    }

    // When there are multiple sibling .jsonl files in the project dir, the Workflow container heuristic
    // must pick the one whose birthtime is closest to the container directory's birthtime.
    func testClaudeWorkflowContainerPicksNearestSiblingByBirthtime() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-claude-workflow-birthtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        let projectDir = projectsDir.appendingPathComponent(
            expectedClaudeProjectDirName(cwd.path),
            isDirectory: true
        )
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let workflowContainerId = "d1d1d1d1-d1d1-d1d1-d1d1-d1d1d1d1d1d1"
        let nearSiblingId = "e2e2e2e2-e2e2-e2e2-e2e2-e2e2e2e2e2e2"
        let farSiblingId = "f3f3f3f3-f3f3-f3f3-f3f3-f3f3f3f3f3f3"
        let workspaceId = UUID()
        let panelId = UUID()

        // Workflow container directory
        let workflowDir = projectDir.appendingPathComponent(workflowContainerId, isDirectory: true)
        try fm.createDirectory(at: workflowDir, withIntermediateDirectories: true)

        // Two sibling transcripts
        let nearURL = projectDir.appendingPathComponent("\(nearSiblingId).jsonl")
        let farURL = projectDir.appendingPathComponent("\(farSiblingId).jsonl")
        try writeClaudeTranscript(sessionId: nearSiblingId, transcriptURL: nearURL, cwd: cwd)
        try writeClaudeTranscript(sessionId: farSiblingId, transcriptURL: farURL, cwd: cwd)

        // Pin birthtimes: container at T, near sibling 5 s after (delta 5), far sibling 60 s after (delta 60).
        let baseDate = Date(timeIntervalSince1970: 1_000_000)
        try fm.setAttributes([.creationDate: baseDate], ofItemAtPath: workflowDir.path)
        try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_000_005)], ofItemAtPath: nearURL.path)
        try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_000_060)], ofItemAtPath: farURL.path)

        try writeClaudeHookStore(
            root: root,
            sessions: [
                workflowContainerId: hookRecord(
                    sessionId: workflowContainerId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    updatedAt: 10
                ),
            ]
        )

        let index = RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
        XCTAssertEqual(
            index.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId,
            nearSiblingId,
            "Workflow container: must pick the sibling transcript whose birthtime is closest to the container directory."
        )
    }

    private func expectedClaudeProjectDirName(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func driftedHookRecord(
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        recordedCwd: String,
        launchCwd: String,
        configDir: String,
        transcriptPath: String?,
        updatedAt: TimeInterval
    ) -> [String: Any] {
        var record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": recordedCwd,
            "pid": NSNull(),
            "updatedAt": updatedAt,
            "launchCommand": [
                "launcher": "claude",
                "executablePath": "/usr/local/bin/claude",
                "arguments": ["/usr/local/bin/claude", "--dangerously-skip-permissions"],
                "workingDirectory": launchCwd,
                "environment": ["CLAUDE_CONFIG_DIR": configDir],
                "capturedAt": updatedAt,
                "source": "test",
            ],
        ]
        if let transcriptPath {
            record["transcriptPath"] = transcriptPath
        }
        return record
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
