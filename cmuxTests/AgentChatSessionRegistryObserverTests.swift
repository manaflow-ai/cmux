#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif
import Testing
import CmuxAgentChat
import Foundation

@MainActor
@Suite struct AgentChatSessionRegistryObserverTests {
    @Test func observerFiresOnInsert() {
        let registry = AgentChatSessionRegistry()
        var seen: [String] = []
        registry.addRecordChangeObserver { record, _ in seen.append(record.sessionID) }
        registry.emitForTest(sessionID: "S1", kind: .claude, workspaceID: "W1",
                             state: .working(since: Date()), pid: 4321)
        #expect(seen == ["S1"])
    }
}
