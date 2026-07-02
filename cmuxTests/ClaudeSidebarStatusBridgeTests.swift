#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif
import Testing
import CmuxAgentChat
import CmuxControlSocket
import CmuxSidebar
import Foundation

@MainActor
@Suite struct ClaudeSidebarStatusBridgeTests {
    private func makeBridge(_ registry: AgentChatSessionRegistry,
                            upsert: @escaping (ControlSidebarTabTarget, SidebarStatusEntry) -> Void = { _, _ in },
                            clear: @escaping (ControlSidebarTabTarget, String) -> Void = { _, _ in }) -> ClaudeSidebarStatusBridge {
        ClaudeSidebarStatusBridge(registry: registry, upsert: upsert, clear: clear)
    }

    @Test func workingClaudeUpsertsToWorkspaceTarget() {
        let registry = AgentChatSessionRegistry()
        let ws = UUID()
        var upserts: [(ControlSidebarTabTarget, SidebarStatusEntry)] = []
        let bridge = makeBridge(registry, upsert: { upserts.append(($0, $1)) })
        _ = bridge
        registry.emitForTest(sessionID: "S1", kind: .claude, workspaceID: ws.uuidString,
                                 state: .working(since: Date()), pid: 4242)
        #expect(upserts.count == 1)
        #expect(upserts.first?.0 == .workspace(ws))
        #expect(upserts.first?.1.value == "Running")
    }

    @Test func endedClaudeClearsTheClaudeKey() {
        let registry = AgentChatSessionRegistry()
        let ws = UUID()
        var clears: [(ControlSidebarTabTarget, String)] = []
        let bridge = makeBridge(registry, clear: { clears.append(($0, $1)) })
        _ = bridge
        registry.emitForTest(sessionID: "S1", kind: .claude, workspaceID: ws.uuidString, state: .working(since: Date()), pid: 1)
        registry.emitForTest(sessionID: "S1", kind: .claude, workspaceID: ws.uuidString, state: .ended, pid: 1)
        #expect(clears.contains { $0.0 == .workspace(ws) && $0.1 == "claude_code" })
    }

    @Test func codexIsIgnored() {
        let registry = AgentChatSessionRegistry()
        var upserts = 0
        let bridge = makeBridge(registry, upsert: { _, _ in upserts += 1 })
        _ = bridge
        registry.emitForTest(sessionID: "C1", kind: .codex, workspaceID: UUID().uuidString, state: .working(since: Date()), pid: 7)
        #expect(upserts == 0)
    }

    @Test func malformedOrNilWorkspaceIsSkipped() {
        let registry = AgentChatSessionRegistry()
        var upserts = 0
        let bridge = makeBridge(registry, upsert: { _, _ in upserts += 1 })
        _ = bridge
        registry.emitForTest(sessionID: "S1", kind: .claude, workspaceID: "not-a-uuid", state: .working(since: Date()), pid: 5)
        registry.emitForTest(sessionID: "S2", kind: .claude, workspaceID: nil, state: .working(since: Date()), pid: 6)
        #expect(upserts == 0)
    }
}
