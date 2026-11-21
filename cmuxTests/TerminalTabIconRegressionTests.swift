import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// A terminal tab shows an agent's mark only while that agent runs in the panel
// (#13299). These tests pin #7822, that the mark goes once the agent does, and
// that a mark never comes from anything but a running agent.
@Suite(.serialized)
struct TerminalTabIconRegressionTests {
    @MainActor
    @Test(arguments: [
        "claude_code",
        "codex",
        "opencode",
        "pi",
        "omp",
        "grok",
        "rovodev",
        "antigravity",
        "hermes-agent",
    ])
    func clearedAgentLeavesNoAgentMark(statusKey: String) throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))
        let key = "\(statusKey).terminal-icon-regression"

        workspace.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)
        workspace.recordAgentPID(
            key: key,
            pid: pid_t(ProcessInfo.processInfo.processIdentifier),
            panelId: panel.id,
            refreshPorts: false
        )
        #expect(workspace.clearAgentPID(key: key, panelId: panel.id, refreshPorts: false))

        try expectNoAgentMark(workspace: workspace, panel: panel, tabId: tabId)
    }

    // #13299: a tab whose title merely looks like an agent command gets no
    // agent mark. Only a detected agent process or a running restored agent
    // names the tab.
    @MainActor
    @Test func agentLookingTitleGetsNoAgentMark() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))

        workspace.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)
        #expect(workspace.updatePanelTitle(panelId: panel.id, title: "codex --yolo"))

        try expectNoAgentMark(workspace: workspace, panel: panel, tabId: tabId)
    }

    @MainActor
    @Test func restoredAgentThatQuitToTheShellLeavesNoAgentMark() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))

        workspace.restoredAgentLifecycle.setSnapshot(
            restoredAgentSnapshot(kind: .codex),
            panelId: panel.id
        )
        workspace.restoredAgentLifecycle.setResumeState(
            .awaitingAutoResumeCommand,
            panelId: panel.id
        )
        workspace.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panel.id] == .autoResumeCommandRunning)
        // The resumed agent marks the tab, so the check below cannot pass
        // just because no mark was ever applied.
        let runningTab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(runningTab.iconAsset == "AgentIcons/Codex")

        // The agent quits and the shell prompt returns.
        workspace.updatePanelShellActivityState(panelId: panel.id, state: .promptIdle)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panel.id] == .completedAgentExit)

        try expectNoAgentMark(workspace: workspace, panel: panel, tabId: tabId)
    }

    // A restored tab that has not resumed its agent yet shows no agent mark:
    // after a relaunch, a tab waiting to auto-resume or offering a manual
    // resume looks like a plain terminal until the agent command runs.
    @MainActor
    @Test func restoredAgentThatHasNotResumedGetsNoAgentMark() throws {
        for state: Workspace.RestoredAgentResumeState in [.awaitingAutoResumeCommand, .manualResumeAvailable] {
            let workspace = Workspace()
            let panel = try #require(workspace.focusedTerminalPanel)
            let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))

            workspace.restoredAgentLifecycle.setSnapshot(
                restoredAgentSnapshot(kind: .codex),
                panelId: panel.id
            )
            workspace.restoredAgentLifecycle.setResumeState(state, panelId: panel.id)
            workspace.syncTerminalTabAgentIconAsset(forPanelId: panel.id)
            #expect(workspace.restoredAgentResumeStatesByPanelId[panel.id] == state)

            try expectNoAgentMark(workspace: workspace, panel: panel, tabId: tabId)
        }
    }

    @MainActor
    @Test func leasedAnimationSurvivesBrandUpdatesAndRevealsLatestBrandOnClear() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabID = try #require(workspace.surfaceIdFromPanelId(panel.id))
        let focusedPanel = workspace.focusedPanelId
        let animation = TabIconAnimation(id: "external-test", frames: [Data([1])], durations: [0.1], loops: true)
        let entry = try workspace.surfaceIconLeases.set(
            panelID: panel.id, ownerID: "cc-island:test", animation: animation
        )
        workspace.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)
        workspace.recordAgentPID(key: "claude_code", pid: pid_t(ProcessInfo.processInfo.processIdentifier), panelId: panel.id, refreshPorts: false)
        workspace.syncTerminalTabAgentIconAsset(forPanelId: panel.id)
        #expect(workspace.bonsplitController.tab(tabID)?.iconAnimation == animation)
        #expect(workspace.bonsplitController.tab(tabID)?.iconAsset == "AgentIcons/Claude")
        #expect(workspace.focusedPanelId == focusedPanel)
        try workspace.surfaceIconLeases.clear(
            panelID: panel.id, ownerID: "cc-island:test", token: entry.token, expectedRevision: entry.revision
        )
        #expect(workspace.bonsplitController.tab(tabID)?.iconAnimation == nil)
        #expect(workspace.bonsplitController.tab(tabID)?.iconAsset == "AgentIcons/Claude")
    }

    @MainActor
    @Test(.timeLimit(.minutes(1))) func expiringAnimationRevealsLatestBrandWithoutChangingFocus() async throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabID = try #require(workspace.surfaceIdFromPanelId(panel.id))
        let focusedPanel = workspace.focusedPanelId
        let clock = CloudReadManualClock()
        let (events, continuation) = AsyncStream<UUID>.makeStream()
        workspace.surfaceIconLeases = SurfaceIconLeaseStore(clock: clock) { [weak workspace] panelID, animation in
            guard let workspace, let tabID = workspace.surfaceIdFromPanelId(panelID) else { return }
            workspace.bonsplitController.updateTab(tabID, iconAnimation: .some(animation))
            if animation == nil { continuation.yield(panelID) }
        }
        let animation = TabIconAnimation(id: "expiring-test", frames: [Data([1])], durations: [0.1], loops: false)
        try workspace.surfaceIconLeases.set(
            panelID: panel.id, ownerID: "test", animation: animation, ttlSeconds: 600
        )
        workspace.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)
        workspace.recordAgentPID(key: "claude_code", pid: pid_t(ProcessInfo.processInfo.processIdentifier), panelId: panel.id, refreshPorts: false)
        workspace.syncTerminalTabAgentIconAsset(forPanelId: panel.id)
        #expect(workspace.bonsplitController.tab(tabID)?.iconAnimation == animation)
        clock.advance(by: .seconds(600))
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == panel.id)
        #expect(workspace.bonsplitController.tab(tabID)?.iconAnimation == nil)
        #expect(workspace.bonsplitController.tab(tabID)?.iconAsset == "AgentIcons/Claude")
        #expect(workspace.focusedPanelId == focusedPanel)
        continuation.finish()
    }

    @MainActor
    @Test(arguments: [false, true])
    func ownershipTransitionClearsIndefiniteIconAndInvalidatesCredentials(cloud: Bool) throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabID = try #require(workspace.surfaceIdFromPanelId(panel.id))
        let animation = TabIconAnimation(id: "ownership-test", frames: [Data([1])], durations: [0.1], loops: true)
        let entry = try workspace.surfaceIconLeases.set(
            panelID: panel.id, ownerID: "local-producer", animation: animation
        )
        #expect(workspace.bonsplitController.tab(tabID)?.iconAnimation == animation)
        if cloud {
            workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "icon-test-machine", isBase: false)
        } else {
            workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
                destination: "icon-test.invalid", port: nil, identityFile: nil, sshOptions: [],
                localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
                localSocketPath: nil, terminalStartupCommand: nil
            )
        }
        #expect(workspace.surfaceIdFromPanelId(panel.id) == tabID)
        #expect(workspace.bonsplitController.tab(tabID)?.iconAnimation == nil)
        #expect(throws: SurfaceIconLeaseStore.LeaseError.staleToken) {
            try workspace.surfaceIconLeases.set(
                panelID: panel.id, ownerID: "local-producer", token: entry.token,
                expectedRevision: entry.revision
            )
        }
        #expect(throws: SurfaceIconLeaseStore.LeaseError.staleToken) {
            try workspace.surfaceIconLeases.clear(
                panelID: panel.id, ownerID: "local-producer", token: entry.token,
                expectedRevision: entry.revision
            )
        }
    }

    @MainActor
    private func expectNoAgentMark(
        workspace: Workspace,
        panel: TerminalPanel,
        tabId: TabID
    ) throws {
        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.iconAsset == nil)
        #expect(tab.iconImageData == nil)
        #expect(tab.icon == panel.displayIcon)
    }

    private func restoredAgentSnapshot(kind: RestorableAgentKind) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: "\(kind.rawValue)-terminal-tab-icon-session",
            workingDirectory: "/tmp/cmux-terminal-tab-icon",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: kind.rawValue,
                executablePath: "/usr/local/bin/\(kind.rawValue)",
                arguments: ["/usr/local/bin/\(kind.rawValue)"],
                workingDirectory: "/tmp/cmux-terminal-tab-icon",
                environment: nil,
                capturedAt: 1_777_777_777,
                source: "test"
            )
        )
    }
}
