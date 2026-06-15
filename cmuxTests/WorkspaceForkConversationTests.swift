import Bonsplit
import Combine
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceForkConversationTests: XCTestCase {
    private func rootSplit(in workspace: Workspace) throws -> ExternalSplitNode {
        switch workspace.bonsplitController.treeSnapshot() {
        case .split(let split):
            return split
        case .pane:
            let split: ExternalSplitNode? = nil
            return try XCTUnwrap(split, "Expected workspace root to be a split")
        }
    }

    private func paneId(in node: ExternalTreeNode) throws -> String {
        switch node {
        case .pane(let pane):
            return pane.id
        case .split:
            let paneId: String? = nil
            return try XCTUnwrap(paneId, "Expected split child to be a pane")
        }
    }

    private func makeForkableClaudeSnapshot(
        sessionId: String = "019dad34-d218-7943-b81a-eddac5c87951",
        workingDirectory: String = "/tmp/fork repo"
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["/opt/homebrew/bin/claude"],
                workingDirectory: workingDirectory,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
    }

    private func makeForkableCodexSnapshot(
        sessionId: String = "019dad34-d218-7943-b81a-eddac5c87951",
        workingDirectory: String = "/tmp/fork repo"
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: workingDirectory,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
    }

    func testForkAgentConversationToNewTabCreatesSiblingTabWithForkStartupInput() throws {
        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId))
        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))
        let snapshot = makeForkableClaudeSnapshot()

        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversationToNewTab(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                anchorTabId: anchorTabId,
                paneId: sourcePaneId
            )
        )

        XCTAssertNotEqual(forkPanel.id, sourcePanelId)
        XCTAssertEqual(
            workspace.paneId(forPanelId: forkPanel.id),
            sourcePaneId,
            "Fork should land in the same pane as the source tab, not a split pane"
        )
        XCTAssertEqual(
            workspace.bonsplitController.allPaneIds.count,
            1,
            "Fork creates a sibling tab, not a new pane"
        )
        XCTAssertEqual(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).count,
            2,
            "Pane should now host both the source and forked tabs"
        )
        XCTAssertEqual(workspace.focusedPanelId, forkPanel.id, "Fork should focus the new tab")
        XCTAssertEqual(forkPanel.requestedWorkingDirectory, "/tmp/fork repo")
        XCTAssertEqual(
            forkPanel.surface.initialInput,
            snapshot.forkCommand.map { $0 + "\n" },
            "Forked tab should boot with the snapshot's --fork-session command"
        )
    }

    func testForkAgentConversationToNewTabPlacesForkImmediatelyRightOfAnchor() throws {
        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId))
        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))

        // Drop a second unrelated terminal tab to the right of the source so we can
        // verify the fork lands *between* the source and the unrelated tab, not at the
        // end of the strip.
        let trailingPanel = try XCTUnwrap(
            workspace.newTerminalSurface(inPane: sourcePaneId, focus: false)
        )
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: sourcePaneId).count, 2)

        let snapshot = makeForkableClaudeSnapshot()
        let forkPanel = try XCTUnwrap(
            workspace.forkAgentConversationToNewTab(
                fromPanelId: sourcePanelId,
                snapshot: snapshot,
                anchorTabId: anchorTabId,
                paneId: sourcePaneId
            )
        )

        let tabIdsInOrder = workspace.bonsplitController.tabs(inPane: sourcePaneId).map(\.id)
        let sourceTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))
        let forkTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(forkPanel.id))
        let trailingTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(trailingPanel.id))
        XCTAssertEqual(
            tabIdsInOrder,
            [sourceTabId, forkTabId, trailingTabId],
            "Fork should be inserted immediately to the right of its source tab"
        )
    }

    func testCanForkAgentConversationFromPanelReturnsTrueForRestoredClaudeSnapshot() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertFalse(workspace.canForkAgentConversationFromPanel(panelId))

        workspace.setRestoredAgentSnapshotForTesting(makeForkableClaudeSnapshot(), panelId: panelId)
        XCTAssertTrue(workspace.canForkAgentConversationFromPanel(panelId))
    }

    func testCanForkAgentConversationFromPanelReturnsFalseForUnknownPanel() {
        let workspace = Workspace()
        XCTAssertFalse(workspace.canForkAgentConversationFromPanel(UUID()))
    }

    func testForkConversationContextMenuAvailabilityUsesProcessDetectedLiveIndex() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let index = SharedLiveAgentIndex.loadIndexForRefresh(
            homeDirectory: FileManager.default.temporaryDirectory.path,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [key: (makeForkableCodexSnapshot(), 123, Set([4_242]), .explicit)]
        )

        XCTAssertTrue(workspace.canForkAgentConversationFromPanel(panelId, liveAgentIndex: index))
    }

    func testForkConversationContextMenuAvailabilityUsesLiveCodexProcessDetection() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let processId = 4_242
        let sessionId = "019dad34-d218-7943-b81a-eddac5c87951"
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: processId,
                    parentPID: 1,
                    name: "codex",
                    path: "/tmp/codex",
                    ttyDevice: nil,
                    cmuxWorkspaceID: workspace.id,
                    cmuxSurfaceID: panelId,
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
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: FileManager.default,
            processSnapshot: processSnapshot,
            capturedAt: 123,
            processArgumentsProvider: { requestedProcessId in
                guard requestedProcessId == processId else { return nil }
                return CmuxTopProcessArguments(
                    arguments: ["/tmp/codex", "resume", sessionId, "--model", "gpt-5.4"],
                    environment: ["PWD": "/tmp/fork repo", "CODEX_HOME": "/tmp/codex"]
                )
            }
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: FileManager.default.temporaryDirectory.path,
            fileManager: FileManager.default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: detectedSnapshots
        )
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspace.id, panelId: panelId))

        XCTAssertEqual(snapshot.kind, .codex)
        XCTAssertEqual(snapshot.sessionId, sessionId)
        XCTAssertEqual(snapshot.launchCommand?.arguments.first, "/tmp/codex")
        XCTAssertEqual(index.processIDs(workspaceId: workspace.id, panelId: panelId), Set([processId]))
        XCTAssertTrue(snapshot.forkCommand?.contains("'fork' '\(sessionId)'") == true)
        XCTAssertTrue(workspace.canForkAgentConversationFromPanel(panelId, liveAgentIndex: index))
        XCTAssertNotNil(detectedSnapshots[key], "Live Codex processes should be indexed by their cmux panel")
    }

    func testForkConversationContextMenuAvailabilityUsesLiveCodexThreadEnvironment() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let processId = 4_243
        let sessionId = "019ec88f-6b52-78e2-ac9b-d8d211ee4d15"
        let processArguments = [
            "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex",
            "-c",
            "openai_base_url=\"http://subrouter-team:31415/v1\"",
        ]
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: processId,
                    parentPID: 1,
                    name: "codex",
                    path: "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex",
                    ttyDevice: nil,
                    cmuxWorkspaceID: workspace.id,
                    cmuxSurfaceID: panelId,
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
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: FileManager.default,
            processSnapshot: processSnapshot,
            capturedAt: 123,
            processArgumentsProvider: { requestedProcessId in
                guard requestedProcessId == processId else { return nil }
                return CmuxTopProcessArguments(
                    arguments: processArguments,
                    environment: [
                        "PWD": "/tmp/fork repo",
                        "CODEX_THREAD_ID": sessionId,
                    ]
                )
            }
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: FileManager.default.temporaryDirectory.path,
            fileManager: FileManager.default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: detectedSnapshots
        )
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspace.id, panelId: panelId))

        XCTAssertEqual(snapshot.kind, .codex)
        XCTAssertEqual(snapshot.sessionId, sessionId)
        XCTAssertEqual(snapshot.launchCommand?.arguments, processArguments)
        XCTAssertEqual(index.processIDs(workspaceId: workspace.id, panelId: panelId), Set([processId]))
        XCTAssertTrue(snapshot.forkCommand?.contains("'fork' '\(sessionId)'") == true)
        XCTAssertTrue(workspace.canForkAgentConversationFromPanel(panelId, liveAgentIndex: index))
        XCTAssertNotNil(detectedSnapshots[key], "Interactive Codex processes should fall back to CODEX_THREAD_ID")
    }

    func testForkConversationContextMenuAvailabilityUsesLiveClaudeTranscriptDetection() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-live-claude-fork-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path), isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let sessionId = "11111111-1111-1111-1111-111111111111"
        let transcriptURL = projectDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try """
        {"type":"user","sessionId":"\(sessionId)","cwd":"\(cwd.path)","message":{"role":"user","content":"hello"}}

        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let processId = 4_244
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: processId,
                    parentPID: 1,
                    name: "claude.exe",
                    path: "/opt/homebrew/bin/claude",
                    ttyDevice: nil,
                    cmuxWorkspaceID: workspace.id,
                    cmuxSurfaceID: panelId,
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
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: fm,
            processSnapshot: processSnapshot,
            capturedAt: 123,
            processArgumentsProvider: { requestedProcessId in
                guard requestedProcessId == processId else { return nil }
                return CmuxTopProcessArguments(
                    arguments: ["claude"],
                    environment: [
                        "PWD": cwd.path,
                        "CLAUDE_CONFIG_DIR": configDir.path,
                    ]
                )
            }
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fm,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: detectedSnapshots
        )
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspace.id, panelId: panelId))

        XCTAssertEqual(snapshot.kind, .claude)
        XCTAssertEqual(snapshot.sessionId, sessionId)
        XCTAssertEqual(snapshot.workingDirectory, cwd.path)
        XCTAssertEqual(index.processIDs(workspaceId: workspace.id, panelId: panelId), Set([processId]))
        XCTAssertTrue(snapshot.forkCommand?.contains("--fork-session") == true)
        XCTAssertTrue(workspace.canForkAgentConversationFromPanel(panelId, liveAgentIndex: index))
        XCTAssertNotNil(detectedSnapshots[key], "Live Claude processes should be indexed from their transcript")
    }

    func testSharedLiveAgentIndexRefreshPublishesWorkspaceAfterNewIndexIsReadable() throws {
        SharedLiveAgentIndex.shared.resetForTesting()
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let index = SharedLiveAgentIndex.loadIndexForRefresh(
            homeDirectory: FileManager.default.temporaryDirectory.path,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [key: (makeForkableCodexSnapshot(), 123, Set([4_242]), .explicit)]
        )

        var workspacePublishedAfterIndexWasReadable = false
        let cancellable = workspace.objectWillChange.sink { _ in
            workspacePublishedAfterIndexWasReadable = workspace.canForkAgentConversationFromPanel(
                panelId,
                liveAgentIndex: SharedLiveAgentIndex.shared.index
            )
        }
        defer {
            cancellable.cancel()
            SharedLiveAgentIndex.shared.resetForTesting()
        }

        SharedLiveAgentIndex.shared.replaceIndexForTesting(index)

        XCTAssertTrue(
            workspacePublishedAfterIndexWasReadable,
            "Tab context-menu availability must be invalidated after the refreshed live-agent index is readable"
        )
    }

    func testForkConversationDefaultSettingFallsBackToRight() throws {
        let suiteName = "cmux.forkConversationDefault.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AgentConversationForkDefaultSettings.current(defaults: defaults), .right)

        defaults.set(AgentConversationForkDestination.newTab.rawValue, forKey: AgentConversationForkDefaultSettings.key)
        XCTAssertEqual(AgentConversationForkDefaultSettings.current(defaults: defaults), .newTab)

        defaults.set("unsupported", forKey: AgentConversationForkDefaultSettings.key)
        XCTAssertEqual(AgentConversationForkDefaultSettings.current(defaults: defaults), .right)
    }

    func testForkConversationContextMenuDefaultActionWorksForCodexSnapshot() throws {
        // Parity coverage with the Claude path: Codex sessions are also `.supportedWithoutProbe`
        // and should reach the default right-split path through the context-menu dispatcher.
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: AgentConversationForkDefaultSettings.key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: AgentConversationForkDefaultSettings.key)
            } else {
                defaults.removeObject(forKey: AgentConversationForkDefaultSettings.key)
            }
        }
        defaults.removeObject(forKey: AgentConversationForkDefaultSettings.key)

        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId))
        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))
        let snapshot = makeForkableCodexSnapshot()
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: sourcePanelId)

        XCTAssertTrue(workspace.canForkAgentConversationFromPanel(sourcePanelId))

        let anchorTab = try XCTUnwrap(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).first { $0.id == anchorTabId }
        )

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .forkConversation,
            for: anchorTab,
            inPane: sourcePaneId
        )

        let forkPanelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertNotEqual(forkPanelId, sourcePanelId, "Codex fork should focus the new split")
        let forkPanel = try XCTUnwrap(workspace.terminalPanel(for: forkPanelId))
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 2)
        XCTAssertEqual(
            forkPanel.surface.initialInput,
            snapshot.forkCommand.map { $0 + "\n" },
            "Codex fork split should boot with the Codex --fork-session command"
        )
        let split = try rootSplit(in: workspace)
        let sourcePaneUUID = sourcePaneId.id.uuidString
        let forkPaneUUID = try XCTUnwrap(workspace.paneId(forPanelId: forkPanelId)).id.uuidString
        XCTAssertEqual(split.orientation, "horizontal")
        XCTAssertEqual(try paneId(in: split.first), sourcePaneUUID)
        XCTAssertEqual(try paneId(in: split.second), forkPaneUUID)
    }

    func testForkConversationContextMenuNewTabActionCreatesSiblingTab() throws {
        // Drive the same code path the bonsplit context menu triggers, end-to-end,
        // to lock in that the menu wiring stays connected.
        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId))
        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))
        workspace.setRestoredAgentSnapshotForTesting(makeForkableClaudeSnapshot(), panelId: sourcePanelId)

        let tabs = workspace.bonsplitController.tabs(inPane: sourcePaneId)
        let anchorTab = try XCTUnwrap(tabs.first { $0.id == anchorTabId })

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .forkConversationNewTab,
            for: anchorTab,
            inPane: sourcePaneId
        )

        XCTAssertEqual(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).count,
            2,
            "Fork Conversation New Tab context action should spawn a sibling tab"
        )
        XCTAssertEqual(
            workspace.bonsplitController.allPaneIds.count,
            1,
            "Fork Conversation New Tab should not create a split pane"
        )
    }

    func testForkConversationContextMenuPrimaryActionUsesConfiguredDefault() throws {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: AgentConversationForkDefaultSettings.key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: AgentConversationForkDefaultSettings.key)
            } else {
                defaults.removeObject(forKey: AgentConversationForkDefaultSettings.key)
            }
        }
        defaults.set(AgentConversationForkDestination.newTab.rawValue, forKey: AgentConversationForkDefaultSettings.key)

        let workspace = Workspace()
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let sourcePaneId = try XCTUnwrap(workspace.paneId(forPanelId: sourcePanelId))
        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(sourcePanelId))
        workspace.setRestoredAgentSnapshotForTesting(makeForkableClaudeSnapshot(), panelId: sourcePanelId)

        let anchorTab = try XCTUnwrap(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).first { $0.id == anchorTabId }
        )

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .forkConversation,
            for: anchorTab,
            inPane: sourcePaneId
        )

        XCTAssertEqual(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).count,
            2,
            "Configured default should control the primary Fork Conversation context action"
        )
        XCTAssertEqual(
            workspace.bonsplitController.allPaneIds.count,
            1,
            "Configured New Tab default should keep the fork in the source pane"
        )
    }
}
