import AppKit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Claude queued prompt monitor")
struct ClaudeQueuedPromptMonitorTests {
    private func queueLine(_ operation: String, _ content: String? = nil) -> String {
        var object: [String: Any] = ["type": "queue-operation", "operation": operation, "sessionId": "active"]
        if let content { object["content"] = content }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Writes a hook store where `active` is the pane's session and a newer
    /// nested session is bound to the same surface.
    private func makeHome(surface: UUID) throws -> (home: URL, transcript: URL, store: URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-queue-\(UUID().uuidString)", isDirectory: true)
        let store = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let transcript = home.appendingPathComponent("active.jsonl")
        let nested = home.appendingPathComponent("nested.jsonl")
        try Data().write(to: transcript)
        try Data().write(to: nested)
        let root: [String: Any] = [
            "activeSessionsBySurface": [surface.uuidString: ["sessionId": "active", "updatedAt": 1.0]],
            "sessions": [
                "active": ["sessionId": "active", "surfaceId": surface.uuidString,
                           "transcriptPath": transcript.path, "updatedAt": 1.0],
                "nested": ["sessionId": "nested", "surfaceId": surface.uuidString,
                           "transcriptPath": nested.path, "updatedAt": 2.0],
            ],
        ]
        let storeFile = store.appendingPathComponent("claude-hook-sessions.json")
        try JSONSerialization.data(withJSONObject: root).write(to: storeFile)
        return (home, transcript, storeFile)
    }

    @Test func followsTheActiveSessionNotTheNewestEntry() throws {
        let surface = UUID()
        let (home, transcript, store) = try makeHome(surface: surface)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(ClaudeQueuedPromptMonitor.activeTranscriptPath(surfaceID: surface, hookStoreURL: store) == transcript.path)
        #expect(ClaudeQueuedPromptMonitor.activeTranscriptPath(surfaceID: UUID(), hookStoreURL: store) == nil)
    }

    @Test func reportsQueuedCountAsTheTranscriptGrows() async throws {
        let surface = UUID()
        let (home, transcript, store) = try makeHome(surface: surface)
        defer { try? FileManager.default.removeItem(at: home) }
        try (queueLine("enqueue", "one") + queueLine("enqueue", "<task-notification>t</task-notification>")
             + queueLine("enqueue", "two") + queueLine("dequeue"))
            .write(to: transcript, atomically: false, encoding: .utf8)

        let counts = CountRecorder()
        let monitor = ClaudeQueuedPromptMonitor(surfaceID: surface, hookStoreURL: store) { count in
            counts.values.append(count)
        }
        await monitor.start()
        #expect(await counts.waitFor(1))

        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(queueLine("popAll", "two").utf8))
        try handle.close()
        #expect(await counts.waitFor(0))
        await monitor.stop()
    }
}

@MainActor
private final class CountRecorder {
    var values: [Int] = []

    func waitFor(_ count: Int) async -> Bool {
        for _ in 0..<150 {
            if values.last == count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return values.last == count
    }
}

@MainActor
@Suite("Terminal agent Edit Queued button", .serialized)
struct TerminalAgentEditQueuedTests {
    private let setting = AgentActionsCatalogSection().promptEditing

    @Test
    func editQueuedShowsForClaudeWithQueuedPromptsAndSendsOneUp() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }
        let view = fixture.panel.hostedView.agentTurnControlView

        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .running)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id) }
        #expect(!view.isEditQueuedVisible, "Nothing is queued yet")
        #expect(view.isHidden, "Stop is off, so the pill has nothing to show")

        view.setQueuedPromptCount(2)
        #expect(view.isEditQueuedVisible)
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        view.clickEditQueuedForTesting()
        view.clickEditQueuedForTesting()

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(after.keyEvents == before.keyEvents + 1, "Two quick clicks send exactly one Up")
        view.setQueuedPromptCount(0)
        #expect(!view.isEditQueuedVisible, "The button hides once the transcript shows the queue popped")
    }

    @Test
    func editQueuedNeverShowsForCodexOrWhenDisabled() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        let view = fixture.panel.hostedView.agentTurnControlView

        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }
        fixture.workspace.setAgentLifecycle(key: "codex", panelId: fixture.panel.id, lifecycle: .running)
        view.setQueuedPromptCount(1)
        #expect(!view.isEditQueuedVisible, "Only Claude's queue is tracked")
        _ = fixture.workspace.clearAgentLifecycle(key: "codex", panelId: fixture.panel.id)

        setting.set(false, in: .standard)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .running)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id) }
        view.setQueuedPromptCount(1)
        #expect(!view.isEditQueuedVisible, "Prompt editing is off")
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
