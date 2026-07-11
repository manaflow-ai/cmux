import CMUXAgentLaunch
import CmuxAgentReplica
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
    @Test func helloAdvertisesSendAndAnswerCapabilities() async throws {
        let service = AgentGUIService(macDeviceID: "mac-test")
        let handler = AgentGUIRPCHandler(service: service)

        let result = await handler.handle(MobileHostRPCRequest(
            id: nil,
            method: GuiWireMethod.hello,
            params: try AgentGUICodableBridge.dictionary(GuiHelloParams(protocolMin: 1, protocolMax: 1, clientCaps: [])),
            auth: nil
        ))
        let payload = try Self.okPayload(result)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(GuiHelloResult.self, from: data)

        #expect(decoded.serverCaps.contains(GuiWireCaps.sendTickets))
        #expect(decoded.serverCaps.contains(GuiWireCaps.answers))
    }

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

    @Test func sendRPCShapesAcceptedAndQueuedResults() async throws {
        let injector = RPCFakeAgentGUITerminalInjector()
        let service = AgentGUIService(macDeviceID: "mac-test", terminalInjector: injector)
        let handler = AgentGUIRPCHandler(service: service)
        let surfaceID = UUID().uuidString
        service.handleHookEventSerial(WorkstreamEvent(
            sessionId: "session-accepted",
            hookEventName: .sessionStart,
            source: "codex",
            surfaceId: surfaceID,
            cwd: "/repo",
            ppid: 123
        ))

        let accepted = await handler.handle(MobileHostRPCRequest(
            id: nil,
            method: GuiWireMethod.send,
            params: try AgentGUICodableBridge.dictionary(GuiSendParams(
                sessionID: AgentSessionID(rawValue: "session-accepted"),
                ticketID: UUID().uuidString,
                text: "hello"
            )),
            auth: nil
        ))
        #expect(try Self.sendResult(accepted) == GuiSendResult(accepted: true, queuedOnMac: false))
        #expect(injector.prompts == ["hello"])

        service.handleHookEventSerial(WorkstreamEvent(
            sessionId: "session-queued",
            hookEventName: .sessionStart,
            source: "codex",
            surfaceId: surfaceID,
            cwd: "/repo",
            ppid: 123
        ))
        service.handleHookEventSerial(WorkstreamEvent(
            sessionId: "session-queued",
            hookEventName: .permissionRequest,
            source: "codex",
            surfaceId: surfaceID,
            cwd: "/repo",
            ppid: 123
        ))
        let queued = await handler.handle(MobileHostRPCRequest(
            id: nil,
            method: GuiWireMethod.send,
            params: try AgentGUICodableBridge.dictionary(GuiSendParams(
                sessionID: AgentSessionID(rawValue: "session-queued"),
                ticketID: UUID().uuidString,
                text: "queued"
            )),
            auth: nil
        ))
        #expect(try Self.sendResult(queued) == GuiSendResult(accepted: true, queuedOnMac: true))
        #expect(injector.prompts == ["hello"])
    }

    @Test func sendRPCErrorsForBindingLostAndAttachments() async throws {
        let injector = RPCFakeAgentGUITerminalInjector()
        injector.result = .bindingLost
        let service = AgentGUIService(macDeviceID: "mac-test", terminalInjector: injector)
        let handler = AgentGUIRPCHandler(service: service)
        service.handleHookEventSerial(WorkstreamEvent(
            sessionId: "session-1",
            hookEventName: .sessionStart,
            source: "codex",
            surfaceId: UUID().uuidString,
            cwd: "/repo",
            ppid: 123
        ))

        let bindingLost = await handler.handle(MobileHostRPCRequest(
            id: nil,
            method: GuiWireMethod.send,
            params: try AgentGUICodableBridge.dictionary(GuiSendParams(
                sessionID: AgentSessionID(rawValue: "session-1"),
                ticketID: UUID().uuidString,
                text: "hello"
            )),
            auth: nil
        ))
        #expect(try Self.failure(bindingLost).code == "binding_lost")

        let attachmentRejected = await handler.handle(MobileHostRPCRequest(
            id: nil,
            method: GuiWireMethod.send,
            params: try AgentGUICodableBridge.dictionary(GuiSendParams(
                sessionID: AgentSessionID(rawValue: "session-1"),
                ticketID: UUID().uuidString,
                text: "hello",
                attachments: [GuiSendAttachment(kind: "image", byteCount: 10)]
            )),
            auth: nil
        ))
        let error = try Self.failure(attachmentRejected)
        #expect(error.code == "send_rejected")
        #expect((error.data as? [String: String])?["detail"] == "attachment_unsupported")
    }

    private static func okPayload(_ result: MobileHostRPCResult?) throws -> [String: Any] {
        guard case .ok(let payload)? = result,
              let dictionary = payload as? [String: Any] else {
            Issue.record("expected ok dictionary")
            throw AgentGUIRPCError.internalError
        }
        return dictionary
    }

    private static func sendResult(_ result: MobileHostRPCResult?) throws -> GuiSendResult {
        let payload = try Self.okPayload(result)
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(GuiSendResult.self, from: data)
    }

    private static func failure(_ result: MobileHostRPCResult?) throws -> MobileHostRPCError {
        guard case .failure(let error)? = result else {
            Issue.record("expected failure")
            throw AgentGUIRPCError.internalError
        }
        return error
    }
}

@MainActor
private final class RPCFakeAgentGUITerminalInjector: AgentGUITerminalInjecting {
    var prompts: [String] = []
    var keys: [String] = []
    var inputs: [String] = []
    var result: AgentGUITerminalInjectionResult = .accepted

    func submitPrompt(surfaceID: String, text: String) -> AgentGUITerminalInjectionResult {
        prompts.append(text)
        return result
    }

    func sendKey(surfaceID: String, keyName: String) -> AgentGUITerminalInjectionResult {
        keys.append(keyName)
        return result
    }

    func sendInput(surfaceID: String, text: String) -> AgentGUITerminalInjectionResult {
        inputs.append(text)
        return result
    }
}
