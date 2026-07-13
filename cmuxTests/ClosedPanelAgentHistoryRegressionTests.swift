import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
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
}
