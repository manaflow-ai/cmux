import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct RemoteTmuxAgentProjectionTests {
    @Test(arguments: ["claude", "codex"])
    func lifecycleReachesDedicatedAndSharedMirrors(agent: String) throws {
        for multiplexed in [false, true] {
            let manager = TabManager()
            let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
            workspace.isRemoteTmuxMirror = true
            let connection = RemoteTmuxControlConnection(
                host: RemoteTmuxHost(destination: "agent-status-test"), sessionName: "work"
            )
            let layout = RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(7))
            connection.windowsByID[1] = RemoteTmuxWindow(id: 1, width: 80, height: 24, layout: layout)
            connection.windowOrder = [1]
            connection.publishedWindowIdByPane = [7: 1]
            let source: any RemoteTmuxSessionSource = multiplexed
                ? RemoteTmuxSessionChannel(underlying: connection, sessionName: "work", sessionId: 1, windowIds: [1])
                : connection
            let mirror = RemoteTmuxSessionMirror(
                host: connection.host, sessionName: "work", connection: source,
                tabManager: manager, workspace: workspace
            )
            defer {
                mirror.detachObserver()
                workspace.teardownAllPanels()
            }
            let key = "cmux.remote.agent:" + (agent == "claude" ? "claude_code" : agent)
            connection.handle(.subscriptionChanged(
                name: "cmux_agent_7", value: "{\"agent\":\"\(agent)\",\"state\":\"working\"}"
            ))
            #expect(workspace.statusEntries[key]?.value == "Running")
            #expect(workspace.agentLifecycleStatesByPanelId.values.contains { $0[key] == .running })
            connection.handle(.subscriptionChanged(
                name: "cmux_agent_7", value: "{\"agent\":\"\(agent)\",\"state\":\"idle\"}"
            ))
            #expect(workspace.statusEntries[key]?.value == "Idle")
            #expect(!workspace.agentLifecycleStatesByPanelId.values.contains { $0[key] == .running })
            connection.handle(.subscriptionChanged(
                name: "cmux_agent_7", value: "{\"agent\":\"\(agent)\",\"state\":\"blocked\"}"
            ))
            #expect(workspace.statusEntries[key]?.value == "Needs input")
            #expect(workspace.agentLifecycleStatesByPanelId.values.contains { $0[key] == .needsInput })
            connection.handle(.subscriptionChanged(name: "cmux_agent_7", value: ""))
            #expect(workspace.statusEntries[key] == nil)
        }
    }

    @Test func workspaceStatusUsesMostUrgentPaneAcrossPanels() throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        workspace.isRemoteTmuxMirror = true
        defer { workspace.teardownAllPanels() }
        let firstPanelID = try #require(workspace.panels.keys.first)
        let secondPanel = try #require(workspace.createReplacementTerminalPanel())
        let projector = RemoteTmuxAgentStatusProjector()
        let key = "cmux.remote.agent:codex"
        let working = try #require(RemoteTmuxAgentStatus.parse(#"{"agent":"codex","state":"working"}"#))
        let blocked = try #require(RemoteTmuxAgentStatus.parse(#"{"agent":"codex","state":"blocked"}"#))

        projector.reconcile(
            statuses: [7: working, 8: blocked],
            panelByPane: [7: firstPanelID, 8: secondPanel.id],
            workspace: workspace
        )

        #expect(workspace.statusEntries[key]?.value == "Needs input")
    }
}
