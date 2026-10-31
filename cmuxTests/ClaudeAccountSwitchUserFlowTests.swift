import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The terminal menu and the palette share one flow: it asks before stopping a running Claude
/// response, a cancel changes nothing, and any result short of a resumed conversation is
/// reported. A resume that was never typed can be typed from the notice, into the respawned
/// pane only. These panes host no Claude, so a real switch ends at `.notClaude` without
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
        #expect(recorder.actions.count == 1)
        #expect(recorder.actions.first.flatMap { $0 } == nil)
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

    @Test
    func typeResumeCommandActionTypesTheBuiltInputIntoTheRespawnedPane() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelId))
        let manualResume = makeManualResume(paneWasReplaced: false)
        let recorder = FlowRecorder(confirms: false)

        recorder.flow.report(
            .switchedWithoutResume(try makePlan(), .copied, manualResume),
            accountName: "work",
            workspace: workspace,
            panelId: panelId
        )

        #expect(recorder.notices.count == 1)
        let typeResumeCommand = try #require(recorder.actions.first.flatMap { $0 })
        #expect(recorder.typedInputs.isEmpty)
        #expect(typeResumeCommand())
        #expect(recorder.typedInputs == [manualResume.typedInput])
        #expect(recorder.typedPanels.count == 1)
        #expect(recorder.typedPanels.first === panel)
    }

    @Test
    func replacedPaneGetsNoTypeResumeCommandAction() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let recorder = FlowRecorder(confirms: false)

        recorder.flow.report(
            .switchedWithoutResume(try makePlan(), .copied, makeManualResume(paneWasReplaced: true)),
            accountName: "work",
            workspace: workspace,
            panelId: panelId
        )

        #expect(recorder.notices.count == 1)
        #expect(recorder.actions.count == 1)
        #expect(recorder.actions.first.flatMap { $0 } == nil)
        #expect(recorder.typedInputs.isEmpty)
    }

    @Test
    func resumeInputIsNotTypedIntoAPaneThatNoLongerHoldsThePanel() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let otherPanel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
        #expect(otherPanel.id != panelId)

        let typed = workspace.typeClaudeAccountSwitchResumeInput("true\n", into: otherPanel, panelId: panelId)

        #expect(!typed)
    }

    private func makeManualResume(paneWasReplaced: Bool) -> ClaudeAccountSwitchManualResume {
        ClaudeAccountSwitchManualResume(
            command: "cd -- '/tmp/project' && env -u CLAUDE_SECURESTORAGE_CONFIG_DIR claude --resume s-1",
            typedInput: "cd -- '/tmp/project' && env -u CLAUDE_SECURESTORAGE_CONFIG_DIR claude --resume s-1\n",
            paneWasReplaced: paneWasReplaced
        )
    }

    private func makePlan() throws -> ClaudeAccountSwitchPlan {
        let home = "/Users/cmux-test"
        return try ClaudeAccountSwitchPlanner.plan(
            sessionID: "s-1",
            workingDirectory: "/tmp/project",
            launchEnvironment: nil,
            targetName: "work",
            registry: ClaudeAccountRegistry(
                declarations: [ClaudeAccountDeclaration(name: "work", configDir: "~/.claude-work")],
                homeDirectory: home
            ),
            homeDirectory: home
        ).get()
    }
}

/// Records what the flow asked, reported and typed in place of its alerts and the terminal.
@MainActor
private final class FlowRecorder {
    private let confirms: Bool
    private(set) var askedAccountNames: [String] = []
    private(set) var notices: [ClaudeAccountSwitchNotice] = []
    private(set) var actions: [(@MainActor () -> Bool)?] = []
    private(set) var typedInputs: [String] = []
    private(set) var typedPanels: [TerminalPanel] = []

    init(confirms: Bool) {
        self.confirms = confirms
    }

    var flow: ClaudeAccountSwitchUserFlow {
        ClaudeAccountSwitchUserFlow(
            confirmStoppingResponse: { [self] name in
                askedAccountNames.append(name)
                return confirms
            },
            presentNotice: { [self] notice, typeResumeCommand in
                notices.append(notice)
                actions.append(typeResumeCommand)
            },
            typeResumeInput: { [self] input, _, panel, _ in
                typedInputs.append(input)
                typedPanels.append(panel)
                return true
            }
        )
    }
}
