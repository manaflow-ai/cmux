import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The terminal menu and the palette share one flow: it asks before stopping a running Claude
/// response, a cancel changes nothing, and any result short of a resumed conversation is
/// reported. These panes host no Claude, so the switch itself ends at `.notClaude` without
/// touching the user's accounts.
@MainActor
@Suite(.serialized)
struct ClaudeAccountSwitchUserFlowTests {
    @Test
    func runningClaudeAsksFirstAndCancelChangesNothing() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelId))
        workspace.setAgentLifecycle(key: Workspace.claudeAgentLifecycleKey, panelId: panelId, lifecycle: .running)
        let recorder = FlowRecorder(confirms: false)

        let result = await recorder.flow.run(workspace: workspace, panelId: panelId, accountName: "work")

        #expect(result == nil)
        #expect(recorder.askedAccountNames == ["work"])
        #expect(recorder.notices.isEmpty)
        #expect(workspace.terminalPanel(for: panelId) === panel)
    }

    @Test
    func runningClaudeSwitchesOnceConfirmedAndReportsTheResult() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: Workspace.claudeAgentLifecycleKey, panelId: panelId, lifecycle: .running)
        let recorder = FlowRecorder(confirms: true)

        let result = await recorder.flow.run(workspace: workspace, panelId: panelId, accountName: "work")

        #expect(result == .notClaude)
        #expect(recorder.askedAccountNames == ["work"])
        #expect(recorder.notices == [.notClaude])
    }

    @Test
    func idlePaneSwitchesWithoutAsking() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let recorder = FlowRecorder(confirms: false)

        let result = await recorder.flow.run(workspace: workspace, panelId: panelId, accountName: "work")

        #expect(result == .notClaude)
        #expect(recorder.askedAccountNames.isEmpty)
        #expect(recorder.notices == [.notClaude])
    }
}

/// Records what the flow asked and reported in place of its alerts.
@MainActor
private final class FlowRecorder {
    private let confirms: Bool
    private(set) var askedAccountNames: [String] = []
    private(set) var notices: [ClaudeAccountSwitchNotice] = []

    init(confirms: Bool) {
        self.confirms = confirms
    }

    var flow: ClaudeAccountSwitchUserFlow {
        ClaudeAccountSwitchUserFlow(
            confirmStoppingResponse: { [self] name in
                askedAccountNames.append(name)
                return confirms
            },
            presentNotice: { [self] notice in notices.append(notice) }
        )
    }
}
