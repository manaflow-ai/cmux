import CmuxControlSocket
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The `chief.*` socket params: what each method accepts and what it refuses
/// before anything runs.
@Suite struct ChiefControlRequestTests {
    private func parse(_ method: String, _ params: [String: Any] = [:]) -> Result<ChiefControlRequest, ChiefControlParamError> {
        ChiefControlRequest.parse(method: method, params: params)
    }

    @Test func simpleMethodsTakeNoParams() {
        #expect(parse("chief.status") == .success(.status))
        #expect(parse("chief.conversations") == .success(.conversations))
        #expect(parse("chief.stop") == .success(.stop(conversation: nil)))
        #expect(parse("chief.stop", ["conversation": " conv_x "]) == .success(.stop(conversation: "conv_x")))
    }

    @Test func openTargetsWindowThenWorkspace() {
        #expect(parse("chief.open") == .success(.open(target: ChiefControlWindowTarget(windowID: nil, workspaceID: nil))))
        #expect(parse("chief.open", ["window_id": "window:2", "workspace_id": "ABC"])
            == .success(.open(target: ChiefControlWindowTarget(windowID: "window:2", workspaceID: "ABC"))))
        #expect(parse("chief.open", ["window_id": 3]) == .failure(.invalid("window_id")))
    }

    @Test func sendAsUserTrimsText() {
        #expect(parse("chief.send", ["text": "  hi Chief \n"])
            == .success(.send(text: "hi Chief", conversation: nil, from: nil, startTurn: true)))
    }

    @Test func sendFromAgentDefaultsToStartingATurn() {
        #expect(parse("chief.send", ["text": "done", "from": "Build Bot", "conversation": "conv_a"])
            == .success(.send(text: "done", conversation: "conv_a", from: "Build Bot", startTurn: true)))
        #expect(parse("chief.send", ["text": "done", "from": "Build Bot", "start_turn": false])
            == .success(.send(text: "done", conversation: nil, from: "Build Bot", startTurn: false)))
    }

    @Test func sendRefusesBadParams() {
        #expect(parse("chief.send") == .failure(.missing("text")))
        #expect(parse("chief.send", ["text": "   "]) == .failure(.invalid("text")))
        #expect(parse("chief.send", ["text": 5]) == .failure(.invalid("text")))
        #expect(parse("chief.send", ["text": String(repeating: "a", count: 65_537)]) == .failure(.tooLong("text")))
        #expect(parse("chief.send", ["text": "x", "from": "  "]) == .failure(.invalid("from")))
        #expect(parse("chief.send", ["text": "x", "from": String(repeating: "n", count: 61)]) == .failure(.tooLong("from")))
        #expect(parse("chief.send", ["text": "x", "start_turn": "yes"]) == .failure(.invalid("start_turn")))
        #expect(parse("chief.send", ["text": "x", "conversation": ""]) == .failure(.invalid("conversation")))
    }

    @Test func readClampsLimit() {
        #expect(parse("chief.read") == .success(.read(conversation: nil, limit: 20)))
        #expect(parse("chief.read", ["limit": 5, "conversation": "conv_b"]) == .success(.read(conversation: "conv_b", limit: 5)))
        #expect(parse("chief.read", ["limit": 10_000]) == .success(.read(conversation: nil, limit: 200)))
        #expect(parse("chief.read", ["limit": 0]) == .failure(.invalid("limit")))
        #expect(parse("chief.read", ["limit": 1.5]) == .failure(.invalid("limit")))
        #expect(parse("chief.read", ["limit": true]) == .failure(.invalid("limit")))
    }

    @Test func debugActions() {
        #expect(parse("chief.debug") == .failure(.missing("action")))
        #expect(parse("chief.debug", ["action": "nope"]) == .failure(.invalid("action")))
        #expect(parse("chief.debug", ["action": "tapback"]) == .success(.debug(.tapback(mine: false), conversation: nil)))
        #expect(parse("chief.debug", ["action": "tapback", "mine": true]) == .success(.debug(.tapback(mine: true), conversation: nil)))
        #expect(parse("chief.debug", ["action": "geometry"]) == .success(.debug(.geometry, conversation: nil)))
        #expect(parse("chief.debug", ["action": "rows", "conversation": "conv_c"]) == .success(.debug(.rows, conversation: "conv_c")))
        #expect(parse("chief.debug", ["action": "messages"]) == .success(.debug(.messages(limit: 10), conversation: nil)))
        #expect(parse("chief.debug", ["action": "scroll", "dy": -120]) == .success(.debug(.scroll(dy: -120), conversation: nil)))
        #expect(parse("chief.debug", ["action": "scroll"]) == .failure(.missing("dy")))
        #expect(parse("chief.debug", ["action": "set-draft", "text": "hello"]) == .success(.debug(.setDraft("hello"), conversation: nil)))
        #expect(parse("chief.debug", ["action": "set_draft", "text": ""]) == .success(.debug(.setDraft(""), conversation: nil)))
        #expect(parse("chief.debug", ["action": "send_draft"]) == .success(.debug(.sendDraft, conversation: nil)))
        #expect(parse("chief.debug", ["action": "theme"]) == .success(.debug(.theme, conversation: nil)))
    }

    @Test func unknownMethodIsNotAParamError() {
        #expect(parse("chief.nope") == .failure(.unknownMethod("chief.nope")))
        #expect(ChiefControlParamError.unknownMethod("chief.nope").parameter == nil)
        #expect(ChiefControlParamError.missing("text").parameter == "text")
    }

    @Test func everyMethodRunsOnTheSocketWorker() {
        for method in ChiefControlRequest.methods {
            #expect(ControlCommandExecutionPolicy(forMethod: method) == .socketWorker(mainThreadCallable: false), "\(method)")
        }
    }

    @Test func onlyOpenHasFocusIntent() {
        for method in ChiefControlRequest.methods {
            #expect(TerminalController.commandHasFocusIntent(commandKey: method, isV2: true, params: [:]) == (method == "chief.open"),
                    "\(method)")
        }
    }
}
