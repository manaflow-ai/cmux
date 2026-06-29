#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif
import Combine
import Testing
import CmuxAgentChat
import Foundation

@MainActor
@Suite struct AgentChatSessionRegistryPublisherTests {
    @Test func publisherFiresOnInsert() {
        let registry = AgentChatSessionRegistry()
        var seen: [String] = []
        var cancellables = Set<AnyCancellable>()
        registry.recordChangesPublisher
            .sink { seen.append($0.record.sessionID) }
            .store(in: &cancellables)

        registry.applyForTesting(sessionID: "S1", kind: .claude, workspaceID: "W1",
                                 state: .working(since: Date()), pid: 4321)
        #expect(seen == ["S1"])
    }
}
