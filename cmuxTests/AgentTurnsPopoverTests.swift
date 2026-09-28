import AppKit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent pane session locator")
struct AgentPaneSessionLocatorTests {
    private func writeStore(_ root: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pane-session-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        return url
    }

    @Test func claudeFollowsTheActivePointerOverNewerEntries() throws {
        let surface = UUID()
        let store = try writeStore([
            "activeSessionsBySurface": [surface.uuidString: ["sessionId": "active"]],
            "sessions": [
                "active": ["surfaceId": surface.uuidString, "transcriptPath": "/t/active.jsonl", "updatedAt": 1.0],
                "nested": ["surfaceId": surface.uuidString, "transcriptPath": "/t/nested.jsonl", "updatedAt": 9.0],
            ],
        ])
        defer { try? FileManager.default.removeItem(at: store) }
        let locator = AgentPaneSessionLocator(agent: .claude, hookStoreURL: store)
        #expect(locator.session(surfaceID: surface) == .init(sessionID: "active", transcriptPath: "/t/active.jsonl"))
        #expect(locator.session(surfaceID: UUID()) == nil)
    }

    @Test func codexUsesTheNewestEntryOnTheSurface() throws {
        let surface = UUID()
        let store = try writeStore([
            "sessions": [
                "old": ["surfaceId": surface.uuidString, "transcriptPath": "/t/old.jsonl", "updatedAt": 1.0],
                "new": ["surfaceId": surface.uuidString.lowercased(), "transcriptPath": "relative.jsonl", "updatedAt": 5.0],
                "other": ["surfaceId": UUID().uuidString, "updatedAt": 9.0],
            ],
        ])
        defer { try? FileManager.default.removeItem(at: store) }
        let session = AgentPaneSessionLocator(agent: .codex, hookStoreURL: store).session(surfaceID: surface)
        #expect(session == .init(sessionID: "new", transcriptPath: nil), "Relative transcript paths are never trusted")
    }
}

@Suite("Turn checkpoints carry the full prompt")
struct VaultCheckpointPromptTextTests {
    @Test func derivedTurnsKeepTheWholePromptForEditing() throws {
        let long = String(repeating: "word ", count: 60) + "\nsecond line"
        let line = try JSONSerialization.data(withJSONObject: [
            "sessionId": "s", "uuid": "u1", "type": "user", "timestamp": "2026-09-28T10:00:00Z",
            "message": ["role": "user", "content": long],
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-prompt-\(UUID().uuidString).jsonl")
        try (line + Data("\n".utf8)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let checkpoint = try #require(VaultSessionCheckpoints.deriveClaudeTurns(fileURL: url).checkpoints.first)
        #expect(checkpoint.promptText == long)
        #expect(checkpoint.promptSnippet != long, "The snippet stays short")
    }
}

@MainActor
@Suite("Terminal agent Turns button", .serialized)
struct TerminalAgentTurnsButtonTests {
    private let setting = AgentActionsCatalogSection().promptEditing

    @Test
    func turnsShowsForAnIdleAgentOnlyWithPromptEditingOn() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        let view = fixture.panel.hostedView.agentTurnControlView
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .idle)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id) }
        #expect(!view.isTurnsVisible, "Prompt editing is off by default")

        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        #expect(view.isTurnsVisible, "An idle agent session still has turns to show")

        _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id)
        #expect(!view.isTurnsVisible, "No agent, no turns")
    }

    @Test
    func editPutsThePromptInTheInputWithoutSending() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .idle)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id) }
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        fixture.panel.putPromptInAgentInput("fix the flaky test")

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(after.pasteTextItems == before.pasteTextItems + 1, "The prompt is pasted")
        #expect(after.keyEvents == before.keyEvents, "No Enter: the prompt is not sent")
    }

    private func makeWorkspaceFixture() throws -> (
        windowID: UUID,
        workspace: Workspace,
        panel: TerminalPanel
    ) {
        let appDelegate = try #require(AppDelegate.shared)
        let windowID = appDelegate.createMainWindow()
        do {
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
            let workspace = try #require(manager.selectedWorkspace)
            let panelID = try #require(workspace.focusedPanelId)
            let panel = try #require(workspace.terminalPanel(for: panelID))
            panel.surface.releaseHostedSurfaceForTesting()
            return (windowID, workspace, panel)
        } catch {
            closeWindow(windowID)
            throw error
        }
    }

    private func closeWindow(_ windowID: UUID) {
        let identifier = "cmux.main.\(windowID.uuidString)"
        NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
    }
}
