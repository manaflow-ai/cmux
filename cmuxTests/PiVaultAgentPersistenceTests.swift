import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class PiVaultAgentPersistenceTests: XCTestCase {
    func testPiVaultAgentSnapshotRoundTripBuildsTargetedSessionCommand() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pi-vault-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionPath = tempDir
            .appendingPathComponent("--tmp-pi repo--", isDirectory: true)
            .appendingPathComponent("2026-05-05T12-00-00-000Z_018f2b35-7c75-7e1a-a6ff-cc1d5f9f0000.jsonl")
            .path
        let panelId = UUID(uuidString: "3D4D5F4B-CA09-4E5C-A65E-8423D7F4BEA0")!
        let piKind = try XCTUnwrap(RestorableAgentKind(rawValue: "pi"))

        var snapshot = makeSnapshot()
        snapshot.windows[0].tabManager.workspaces[0].focusedPanelId = panelId
        snapshot.windows[0].tabManager.workspaces[0].layout = .pane(
            SessionPaneLayoutSnapshot(panelIds: [panelId], selectedPanelId: panelId)
        )
        snapshot.windows[0].tabManager.workspaces[0].panels = [
            SessionPanelSnapshot(
                id: panelId,
                type: .terminal,
                title: "Pi",
                customTitle: nil,
                directory: "/tmp/pi repo",
                isPinned: false,
                isManuallyUnread: false,
                gitBranch: nil,
                listeningPorts: [],
                ttyName: "ttys001",
                terminal: SessionTerminalPanelSnapshot(
                    workingDirectory: "/tmp/pi repo",
                    scrollback: nil,
                    agent: SessionRestorableAgentSnapshot(
                        kind: piKind,
                        sessionId: sessionPath,
                        workingDirectory: "/tmp/pi repo",
                        launchCommand: AgentLaunchCommandSnapshot(
                            launcher: "pi",
                            executablePath: "/opt/homebrew/bin/pi",
                            arguments: ["/opt/homebrew/bin/pi", "--session-dir", tempDir.path, "--session", "old-session", "--continue"],
                            workingDirectory: "/tmp/pi repo",
                            environment: ["PI_CODING_AGENT_SESSION_DIR": tempDir.path],
                            capturedAt: 1_777_777_777,
                            source: "process"
                        )
                    ),
                    tmuxStartCommand: nil
                ),
                browser: nil,
                markdown: nil,
                filePreview: nil
            )
        ]

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))
        let loadedAgent = try XCTUnwrap(
            SessionPersistenceStore.load(fileURL: snapshotURL)?.windows.first?
                .tabManager.workspaces.first?.panels.first?.terminal?.agent
        )

        XCTAssertEqual(loadedAgent.kind.rawValue, "pi")
        XCTAssertEqual(loadedAgent.sessionId, sessionPath)
        XCTAssertEqual(
            loadedAgent.resumeCommand,
            "cd '/tmp/pi repo' && '/opt/homebrew/bin/pi' '--session' '\(sessionPath)'"
        )
    }

    private func makeSnapshot() -> AppSessionSnapshot {
        let workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: "Restored",
            customColor: nil,
            isPinned: true,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        return AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: [
                SessionWindowSnapshot(
                    frame: SessionRectSnapshot(x: 10, y: 20, width: 900, height: 700),
                    display: nil,
                    tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [workspace]),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
                )
            ]
        )
    }
}
