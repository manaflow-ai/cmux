import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
    @MainActor
    @Test func completedRootExitCannotBeReattachedByColdIndexEnrichment() {
        #expect(!Workspace.closedPanelAgentEnrichmentAllowed(resumeState: .completedAgentExit))
        #expect(Workspace.closedPanelAgentEnrichmentAllowed(resumeState: nil))
        #expect(Workspace.closedPanelAgentEnrichmentAllowed(resumeState: .manualResumeAvailable))
    }

    @MainActor
    @Test func coldAgentIndexCanEnrichAnAlreadyClosedPanelWithoutBlockingClose() throws {
        let panelId = UUID()
        let panelData = try JSONSerialization.data(withJSONObject: [
            "id": panelId.uuidString,
            "type": "terminal",
            "isPinned": false,
            "isManuallyUnread": false,
            "listeningPorts": [],
            "terminal": ["workingDirectory": "/tmp/project"],
        ])
        let panel = try JSONDecoder().decode(SessionPanelSnapshot.self, from: panelData)
        let store = ClosedItemHistoryStore(capacity: 10)
        let recordId = store.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: UUID(), paneId: UUID(), tabIndex: 0, snapshot: panel
        )))
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex, sessionId: "codex-session", workingDirectory: "/tmp/project", launchCommand: nil
        )

        #expect(store.enrichClosedPanelAgent(recordId: recordId, agent: agent))

        var restored: ClosedItemHistoryEntry?
        #expect(!store.restoreFirstRestorable { entry in
            restored = entry
            return false
        })
        guard case .panel(let entry) = try #require(restored) else {
            Issue.record("Expected a panel history entry")
            return
        }
        #expect(entry.snapshot.terminal?.agent?.sessionId == "codex-session")
    }

    @MainActor
    @Test func coldAgentIndexCanEnrichAnAlreadyClosedWorkspaceWithoutBlockingClose() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let panelData = try JSONSerialization.data(withJSONObject: [
            "id": panelId.uuidString,
            "type": "terminal",
            "isPinned": false,
            "isManuallyUnread": false,
            "listeningPorts": [],
            "terminal": ["workingDirectory": "/tmp/project"],
        ])
        let panel = try JSONDecoder().decode(SessionPanelSnapshot.self, from: panelData)
        let snapshot = SessionWorkspaceSnapshot(
            workspaceId: workspaceId,
            processTitle: "Agent workspace",
            customTitle: nil,
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            terminalScrollBarHidden: nil,
            currentDirectory: "/tmp/project",
            focusedPanelId: panelId,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelId], selectedPanelId: panelId)),
            panels: [panel],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            remote: nil
        )
        let store = ClosedItemHistoryStore(capacity: 10)
        let recordId = store.push(.workspace(ClosedWorkspaceHistoryEntry(
            workspaceId: workspaceId, windowId: nil, workspaceIndex: 0, snapshot: snapshot
        )))
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex, sessionId: "workspace-codex", workingDirectory: "/tmp/project", launchCommand: nil
        )

        #expect(store.enrichClosedWorkspaceAgents(recordId: recordId, agentsByPanelId: [panelId: agent]))

        var restored: ClosedItemHistoryEntry?
        #expect(!store.restoreFirstRestorable { entry in restored = entry; return false })
        guard case .workspace(let entry) = try #require(restored) else {
            Issue.record("Expected a workspace history entry")
            return
        }
        #expect(entry.snapshot.panels.first?.terminal?.agent?.sessionId == "workspace-codex")
    }
}
