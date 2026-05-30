import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Running agents sidebar model")
struct RunningAgentsSidebarModelBuilderTests {
    @Test("Lists visible agent rows sorted by attention state")
    func listsVisibleAgentRowsSortedByAttentionState() throws {
        let runningWorkspace = Workspace()
        runningWorkspace.title = "Build"
        let runningPanelId = try #require(runningWorkspace.focusedPanelId)
        runningWorkspace.recordAgentPID(key: "codex", pid: 111, panelId: runningPanelId, refreshPorts: false)
        runningWorkspace.statusEntries["codex"] = SidebarStatusEntry(
            key: "codex",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF"
        )
        runningWorkspace.setAgentLifecycle(key: "codex", panelId: runningPanelId, lifecycle: .running)

        let needsInputWorkspace = Workspace()
        needsInputWorkspace.title = "Review"
        let needsInputPanelId = try #require(needsInputWorkspace.focusedPanelId)
        needsInputWorkspace.recordAgentPID(key: "grok", pid: 222, panelId: needsInputPanelId, refreshPorts: false)
        needsInputWorkspace.statusEntries["grok"] = SidebarStatusEntry(
            key: "grok",
            value: "Needs input",
            icon: "exclamationmark.circle.fill",
            color: "#F59E0B"
        )
        needsInputWorkspace.setAgentLifecycle(key: "grok", panelId: needsInputPanelId, lifecycle: .needsInput)

        let idleWorkspace = Workspace()
        idleWorkspace.title = "Docs"
        let idlePanelId = try #require(idleWorkspace.focusedPanelId)
        idleWorkspace.recordAgentPID(key: "amp", pid: 333, panelId: idlePanelId, refreshPorts: false)
        idleWorkspace.statusEntries["amp"] = SidebarStatusEntry(key: "amp", value: "Idle")
        idleWorkspace.setAgentLifecycle(key: "amp", panelId: idlePanelId, lifecycle: .idle)

        let unknownWorkspace = Workspace()
        let unknownPanelId = try #require(unknownWorkspace.focusedPanelId)
        unknownWorkspace.recordAgentPID(key: "gemini", pid: 444, panelId: unknownPanelId, refreshPorts: false)
        unknownWorkspace.statusEntries["gemini"] = SidebarStatusEntry(key: "gemini", value: "Unknown")
        unknownWorkspace.setAgentLifecycle(key: "gemini", panelId: unknownPanelId, lifecycle: .unknown)

        let builder = RunningAgentsSidebarModelBuilder { workspaceId, surfaceId in
            workspaceId == needsInputWorkspace.id && surfaceId == needsInputPanelId ? "Approval requested" : nil
        }

        let rows = builder.items(for: [
            runningWorkspace,
            needsInputWorkspace,
            idleWorkspace,
            unknownWorkspace,
        ])

        #expect(rows.map(\.agentKey) == ["grok", "codex", "amp"])
        #expect(rows.map(\.lifecycleState) == [.needsInput, .running, .idle])
        #expect(rows[0].workspaceName == "Review")
        #expect(rows[0].surfaceId == needsInputPanelId)
        #expect(rows[0].statusText == "Needs input")
        #expect(rows[0].latestNotificationText == "Approval requested")
        #expect(rows[1].workspaceName == "Build")
        #expect(rows[1].surfaceId == runningPanelId)
        #expect(rows[1].statusIcon == "bolt.fill")
        #expect(rows[1].statusColor == "#4C8DFF")
    }

    @Test("Uses the same visible structured status source as sidebar metadata")
    func usesSameVisibleStructuredStatusSourceAsSidebarMetadata() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.statusEntries["codex"] = SidebarStatusEntry(key: "codex", value: "Running")
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        #expect(RunningAgentsSidebarModelBuilder().items(for: [workspace]).isEmpty)

        workspace.recordAgentPID(key: "codex", pid: 111, panelId: panelId, refreshPorts: false)

        let rows = RunningAgentsSidebarModelBuilder().items(for: [workspace])
        #expect(rows.map(\.agentKey) == ["codex"])
        #expect(rows.first?.surfaceId == panelId)
    }
}
