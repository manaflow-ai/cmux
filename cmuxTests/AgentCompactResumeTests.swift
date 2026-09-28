import AppKit
import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent recent prompt reader")
struct AgentRecentPromptReaderTests {
    @Test func readsTheLatestClaudePromptsAndSkipsTheCompactSummary() throws {
        let lines: [[String: Any]] = [
            ["type": "user", "uuid": "1", "message": ["role": "user", "content": "first task"]],
            ["type": "assistant", "uuid": "2", "message": ["role": "assistant", "content": "ok"]],
            ["type": "user", "uuid": "3", "message": ["role": "user", "content": "fix the flaky sidebar test"]],
            ["type": "user", "uuid": "4", "isCompactSummary": true,
             "message": ["role": "user", "content": "This session is being continued from a previous conversation"]],
        ]
        var data = Data()
        for line in lines {
            data.append(try JSONSerialization.data(withJSONObject: line))
            data.append(Data("\n".utf8))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-prompts-\(UUID().uuidString).jsonl")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let prompts = AgentRecentPromptReader(agent: .claudeCode).prompts(transcriptURL: url)
        #expect(prompts == ["first task", "fix the flaky sidebar test"])

        // The last two lines plus the cut end of the line before them.
        let lastTwo = data.split(separator: UInt8(ascii: "\n")).suffix(2).reduce(0) { $0 + $1.count + 1 }
        let tail = AgentRecentPromptReader(agent: .claudeCode, tailBytes: lastTwo + 5).prompts(transcriptURL: url)
        #expect(tail == ["fix the flaky sidebar test"], "A tail read drops the cut line and finds the latest prompt")
    }
}

@MainActor
@Suite("Terminal agent compact and resume", .serialized)
struct TerminalAgentCompactResumeTests {
    @Test
    func idleAgentIsCompactedThenResumedOnPostCompact() async throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        let panel = fixture.panel
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: panel.id, lifecycle: .idle)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: panel.id) }
        let before = panel.surface.debugPendingSocketInputForTesting()

        let start = await panel.startAgentCompactResume(timing: .now, readInput: { _ in .empty })

        #expect(start == .started(.claudeCode))
        let compacting = panel.surface.debugPendingSocketInputForTesting()
        #expect(compacting.pasteTextItems == before.pasteTextItems + 1, "/compact is typed")
        #expect(compacting.keyEvents == before.keyEvents + 1, "and submitted")
        #expect(panel.hostedView.agentTurnControlView.compactResumeStatus != nil, "The pill shows progress")

        AgentCompactionReport(source: "claude", sessionID: "other", surfaceID: UUID()).post()
        #expect(counts(panel) == counts(compacting), "Another pane's compaction is ignored")

        AgentCompactionReport(source: "claude", sessionID: "s", surfaceID: panel.id).post()
        let resumed = panel.surface.debugPendingSocketInputForTesting()
        #expect(resumed.pasteTextItems == compacting.pasteTextItems + 1, "The continue prompt is typed")
        #expect(resumed.keyEvents == compacting.keyEvents + 1, "and submitted")
        #expect(panel.agentCompactResumeRun == nil)
        #expect(panel.hostedView.agentTurnControlView.compactResumeStatus == nil)
    }

    @Test
    func runningAgentIsInterruptedOnceThenCompactedWhenIdle() async throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        let panel = fixture.panel
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: panel.id, lifecycle: .running)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: panel.id) }
        let before = panel.surface.debugPendingSocketInputForTesting()

        let start = await panel.startAgentCompactResume(
            timing: .now,
            readInput: { _ in .empty },
            settleInterval: .milliseconds(1)
        )

        #expect(start == .started(.claudeCode))
        let interrupted = panel.surface.debugPendingSocketInputForTesting()
        #expect(interrupted.keyEvents == before.keyEvents + 1, "One Escape")
        #expect(interrupted.pasteTextItems == before.pasteTextItems, "Nothing typed into a running turn")

        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: panel.id, lifecycle: .idle)
        try await waitUntil { panel.surface.debugPendingSocketInputForTesting().pasteTextItems > interrupted.pasteTextItems }
        let compacting = panel.surface.debugPendingSocketInputForTesting()
        #expect(compacting.pasteTextItems == interrupted.pasteTextItems + 1, "/compact after the settle wait")
        #expect(compacting.keyEvents == interrupted.keyEvents + 1, "Return, and no second Escape")
        panel.agentCompactResumeRun?.timeOutForTesting()
    }

    @Test
    func idleTimingWaitsWithoutInterrupting() async throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        let panel = fixture.panel
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: panel.id, lifecycle: .running)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: panel.id) }
        let before = panel.surface.debugPendingSocketInputForTesting()

        #expect(await panel.startAgentCompactResume(timing: .idle, readInput: { _ in .empty }) == .started(.claudeCode))
        #expect(counts(panel) == counts(before), "No Escape, nothing typed")
        #expect(await panel.startAgentCompactResume(timing: .idle, readInput: { _ in .empty }) == .alreadyRunning)

        panel.agentCompactResumeRun?.timeOutForTesting()
        #expect(panel.agentCompactResumeRun == nil)
        #expect(counts(panel) == counts(before), "A timeout types nothing")
    }

    @Test
    func needsInputAndDraftsAreRefusedWithoutTyping() async throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        let panel = fixture.panel
        let before = panel.surface.debugPendingSocketInputForTesting()

        #expect(await panel.startAgentCompactResume(timing: .now, readInput: { _ in .empty }) == .refused(.noAgent))

        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: panel.id, lifecycle: .needsInput)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: panel.id) }
        #expect(await panel.startAgentCompactResume(timing: .now, readInput: { _ in .empty }) == .refused(.blocked))

        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: panel.id, lifecycle: .idle)
        #expect(await panel.startAgentCompactResume(timing: .now, readInput: { _ in .hasText }) == .refused(.inputNotEmpty))
        #expect(
            panel.hostedView.agentTurnControlView.compactResumeStatus
                == AgentCompactResumeStopReason.inputNotEmpty.localizedMessage,
            "The pill says why nothing happened"
        )

        #expect(counts(panel) == counts(before))
        #expect(panel.agentCompactResumeRun == nil)
    }

    @Test
    func socketPathRefusesAnUnreadableInput() async throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        let panel = fixture.panel
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: panel.id, lifecycle: .idle)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: panel.id) }
        let before = panel.surface.debugPendingSocketInputForTesting()

        // The test surface has no live screen, so the real input reader
        // can't see the agent's input line and nothing may be typed.
        let start = await TerminalController.startAgentCompactResume(surfaceID: panel.id, timing: .now, focus: nil)
        #expect(start == .refused(.inputUnreadable))
        #expect(counts(panel) == counts(before))
        #expect(await TerminalController.startAgentCompactResume(surfaceID: UUID(), timing: .now, focus: nil) == nil)
    }

    private typealias Pending = (
        items: Int, bytes: Int, keyEvents: Int, pasteTextItems: Int, inputTextItems: Int, processOutputItems: Int
    )

    /// Keys, pastes and typed text queued for the test surface.
    private func counts(_ pending: Pending) -> [Int] {
        [pending.keyEvents, pending.pasteTextItems, pending.inputTextItems]
    }

    private func counts(_ panel: TerminalPanel) -> [Int] {
        counts(panel.surface.debugPendingSocketInputForTesting())
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
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
