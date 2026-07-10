import CMUXAgentLaunch
import CmuxAgentWire
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct AgentGUIRPCHandlerTests {
    @Test func sessionsResultEncodesWireShapeFromReducerSnapshot() throws {
        let service = AgentGUIService(macDeviceID: "mac-test")
        service.handleHookEventSerial(WorkstreamEvent(
            sessionId: "session-1",
            hookEventName: .sessionStart,
            source: "codex",
            surfaceId: "surface-1",
            cwd: "/repo",
            ppid: 123
        ))

        let dictionary = try AgentGUICodableBridge.dictionary(service.sessionsResult())
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(GuiSessionsResult.self, from: data)

        #expect(decoded.epoch == service.epoch)
        #expect(decoded.sessions.count == 1)
        #expect(decoded.sessions.first?.id.rawValue == "session-1")
        #expect(decoded.sessions.first?.macDeviceID.rawValue == "mac-test")
    }
}
