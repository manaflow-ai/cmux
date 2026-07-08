import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ClaudeForkFallbackSessionIndexTests: XCTestCase {
    func testUnpromptedForkPaneUsesParentSessionFallbackWithoutStealingParentPane() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let detected = detectedSnapshots(
            fixture: fixture,
            argv: ["/usr/local/bin/claude", "--resume", fixture.parentSessionId, "--fork-session", "--model", "sonnet"]
        )
        let index = loadIndex(fixture: fixture, detectedSnapshots: detected)

        let forkSnapshot = try XCTUnwrap(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId))
        XCTAssertEqual(forkSnapshot.kind, .claude)
        XCTAssertEqual(forkSnapshot.sessionId, fixture.parentSessionId)
        XCTAssertEqual(forkSnapshot.workingDirectory, fixture.cwd.path)
        XCTAssertEqual(forkSnapshot.launchCommand?.arguments, ["/usr/local/bin/claude", "--model", "sonnet"])
        let forkCommand = try XCTUnwrap(forkSnapshot.forkCommand)
        XCTAssertTrue(forkCommand.contains(fixture.parentSessionId), forkCommand)
        XCTAssertTrue(forkCommand.contains("--fork-session"), forkCommand)

        let parentSnapshot = try XCTUnwrap(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.parentPanelId))
        XCTAssertEqual(parentSnapshot.sessionId, fixture.parentSessionId)
    }

    func testPromptedForkPaneHookIdentityWinsOverParentFallback() throws {
        let fixture = try makeFixture(forkedSessionId: "bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb")
        defer { fixture.cleanup() }

        let detected = detectedSnapshots(
            fixture: fixture,
            argv: ["/usr/local/bin/claude", "--resume", fixture.parentSessionId, "--fork-session"]
        )
        let index = loadIndex(fixture: fixture, detectedSnapshots: detected)

        let forkSnapshot = try XCTUnwrap(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId))
        XCTAssertEqual(forkSnapshot.sessionId, try XCTUnwrap(fixture.forkedSessionId))
        XCTAssertEqual(index.processIDs(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId), [fixture.forkProcessID])
    }

    func testForkParentFallbackIgnoresWrapperInjectedSessionID() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let detected = detectedSnapshots(
            fixture: fixture,
            argv: [
                "/usr/local/bin/claude",
                "--session-id", "cccccccc-3333-3333-3333-cccccccccccc",
                "--resume", fixture.parentSessionId,
                "--fork-session",
            ]
        )

        XCTAssertNil(detected[RestorableAgentSessionIndex.PanelKey(
            workspaceId: fixture.workspaceId,
            panelId: fixture.forkPanelId
        )])
    }

    func testForkParentFallbackDoesNotEvictParentHookEntryForSameSession() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let detected = detectedSnapshots(
            fixture: fixture,
            argv: ["/usr/local/bin/claude", "--resume=\(fixture.parentSessionId)", "--fork-session=true"]
        )
        let index = loadIndex(fixture: fixture, detectedSnapshots: detected)

        XCTAssertEqual(
            index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.parentPanelId)?.sessionId,
            fixture.parentSessionId
        )
        XCTAssertEqual(
            index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId)?.sessionId,
            fixture.parentSessionId
        )
    }

    func testUnpromptedForkPaneIsForkValidatedFromLiveProcessFallback() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let processSnapshot = snapshot(fixture: fixture)
        let processArguments = claudeProcessArguments(
            fixture: fixture,
            argv: ["/usr/local/bin/claude", "-r", fixture.parentSessionId, "--fork-session", "--model", "sonnet"]
        )
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(fixture.forkProcessID),
            startSeconds: 1,
            startMicroseconds: 2
        )
        let result = SharedLiveAgentIndexLoader(
            homeDirectory: fixture.root.path,
            fileManager: fixture.fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            processSnapshotProvider: { processSnapshot },
            capturedAtProvider: { 42 },
            processArgumentsProvider: { $0 == fixture.forkProcessID ? processArguments : nil },
            processIdentityProvider: { $0 == fixture.forkProcessID ? identity : nil }
        ).loadResultSynchronously()

        XCTAssertTrue(result.forkValidatedPanels.contains(RestorableAgentSessionIndex.PanelKey(
            workspaceId: fixture.workspaceId,
            panelId: fixture.forkPanelId
        )))
    }

    private struct Fixture {
        let fileManager: FileManager
        let root: URL
        let cwd: URL
        let configDir: URL
        let workspaceId: UUID
        let parentPanelId: UUID
        let forkPanelId: UUID
        let parentSessionId: String
        let forkedSessionId: String?
        let forkProcessID: Int

        func cleanup() {
            try? fileManager.removeItem(at: root)
        }
    }

    private func makeFixture(forkedSessionId: String? = nil) throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-claude-fork-fallback-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let projectDir = projectsDir.appendingPathComponent(
            RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path),
            isDirectory: true
        )
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let workspaceId = UUID()
        let parentPanelId = UUID()
        let forkPanelId = UUID()
        let parentSessionId = "aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa"
        try writeTranscript(sessionId: parentSessionId, transcriptDir: projectDir, cwd: cwd)

        var sessions = [
            parentSessionId: hookRecord(
                sessionId: parentSessionId,
                workspaceId: workspaceId,
                panelId: parentPanelId,
                cwd: cwd.path,
                configDir: configDir.path,
                updatedAt: 10
            ),
        ]
        if let forkedSessionId {
            try writeTranscript(sessionId: forkedSessionId, transcriptDir: projectDir, cwd: cwd)
            sessions[forkedSessionId] = hookRecord(
                sessionId: forkedSessionId,
                workspaceId: workspaceId,
                panelId: forkPanelId,
                cwd: cwd.path,
                configDir: configDir.path,
                updatedAt: 20
            )
        }
        try writeHookStore(root: root, sessions: sessions)

        return Fixture(
            fileManager: fm,
            root: root,
            cwd: cwd,
            configDir: configDir,
            workspaceId: workspaceId,
            parentPanelId: parentPanelId,
            forkPanelId: forkPanelId,
            parentSessionId: parentSessionId,
            forkedSessionId: forkedSessionId,
            forkProcessID: 4_242
        )
    }

    private func detectedSnapshots(
        fixture: Fixture,
        argv: [String]
    ) -> [RestorableAgentSessionIndex.PanelKey: RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry] {
        let processArguments = claudeProcessArguments(fixture: fixture, argv: argv)
        return RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: fixture.fileManager,
            processSnapshot: snapshot(fixture: fixture),
            capturedAt: 42,
            processArgumentsProvider: { $0 == fixture.forkProcessID ? processArguments : nil }
        )
    }

    private func loadIndex(
        fixture: Fixture,
        detectedSnapshots: [RestorableAgentSessionIndex.PanelKey: RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry]
    ) -> RestorableAgentSessionIndex {
        RestorableAgentSessionIndex.load(
            homeDirectory: fixture.root.path,
            fileManager: fixture.fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: detectedSnapshots,
            processArgumentsProvider: { _ in nil }
        )
    }

    private func snapshot(fixture: Fixture) -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: fixture.forkProcessID,
                    parentPID: 1,
                    name: "claude",
                    path: "/usr/local/bin/claude",
                    ttyDevice: nil,
                    cmuxWorkspaceID: fixture.workspaceId,
                    cmuxSurfaceID: fixture.forkPanelId,
                    cmuxAttributionReason: "cmux-test",
                    processGroupID: nil,
                    terminalProcessGroupID: nil,
                    cpuPercent: 0,
                    residentBytes: 0,
                    virtualBytes: 0,
                    threadCount: 1
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
    }

    private func claudeProcessArguments(fixture: Fixture, argv: [String]) -> CmuxTopProcessArguments {
        CmuxTopProcessArguments(
            arguments: argv,
            environment: [
                "CMUX_AGENT_LAUNCH_KIND": "claude",
                "CMUX_AGENT_LAUNCH_CWD": fixture.cwd.path,
                "CMUX_WORKSPACE_ID": fixture.workspaceId.uuidString,
                "CMUX_SURFACE_ID": fixture.forkPanelId.uuidString,
                "CLAUDE_CONFIG_DIR": fixture.configDir.path,
                "PWD": fixture.cwd.path,
            ]
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
        [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": cwd,
            "pid": NSNull(),
            "updatedAt": updatedAt,
            "launchCommand": [
                "launcher": "claude",
                "executablePath": "/usr/local/bin/claude",
                "arguments": ["/usr/local/bin/claude"],
                "workingDirectory": cwd,
                "environment": ["CLAUDE_CONFIG_DIR": configDir],
                "capturedAt": updatedAt,
                "source": "test",
            ],
        ]
    }

    private func writeTranscript(sessionId: String, transcriptDir: URL, cwd: URL) throws {
        try """
        {"type":"last-prompt","sessionId":"\(sessionId)"}
        {"type":"user","sessionId":"\(sessionId)","cwd":"\(cwd.path)","message":{"role":"user","content":"hello"}}

        """.write(
            to: transcriptDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeHookStore(root: URL, sessions: [String: [String: Any]]) throws {
        let store: [String: Any] = ["version": 1, "sessions": sessions]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
        try data.write(to: root.appendingPathComponent("claude-hook-sessions.json"), options: .atomic)
    }
}
