import CmuxControlSocket
import CmuxHomeCore
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
        #expect(parse("chief.conversations", ["after_cursor": "cursor-1", "wait_for_change": true])
            == .success(.conversationsAfter(cursor: "cursor-1")))
        #expect(parse("chief.conversations", ["after_cursor": "cursor-1"]) == .failure(.invalid("after_cursor")))
        #expect(parse("chief.mark_read") == .failure(.missing("up_to_seq")))
        #expect(parse("chief.mark_read", ["up_to_seq": 7, "conversation": "conv_x"])
            == .success(.markRead(conversation: "conv_x", upToSeq: 7)))
        #expect(parse("chief.stop") == .success(.stop(conversation: nil)))
        #expect(parse("chief.stop", ["conversation": " conv_x "]) == .success(.stop(conversation: "conv_x")))
    }

    @Test func approveNeedsAChoiceAndTakesAnOptionalRequest() {
        #expect(parse("chief.approve") == .failure(.missing("choice")))
        #expect(parse("chief.approve", ["choice": "Allow"]) == .success(.approve(conversation: nil, request: nil, choice: "Allow")))
        #expect(parse("chief.approve", ["request": " scripted-approval-1 ", "choice": "Deny", "conversation": "conv_a"])
            == .success(.approve(conversation: "conv_a", request: "scripted-approval-1", choice: "Deny")))
        #expect(parse("chief.approve", ["choice": "  "]) == .failure(.invalid("choice")))
        #expect(parse("chief.approve", ["choice": true]) == .failure(.invalid("choice")))
    }

    @Test func answerTakesChoicesTextAndAnOptionalMessage() {
        // Neither: the card's preselection, as pressing its Submit right away.
        #expect(parse("chief.answer") == .success(.answer(conversation: nil, message: nil, choices: [], text: nil)))
        #expect(parse("chief.answer", ["choices": [" 4 GB ", "Existing"], "message": " msg_1 ", "conversation": "conv_a"])
            == .success(.answer(conversation: "conv_a", message: "msg_1", choices: ["4 GB", "Existing"], text: nil)))
        // One string is one choice; null is none.
        #expect(parse("chief.answer", ["choices": "8 GB"]) == .success(.answer(conversation: nil, message: nil, choices: ["8 GB"], text: nil)))
        #expect(parse("chief.answer", ["choices": NSNull(), "text": " call it api "])
            == .success(.answer(conversation: nil, message: nil, choices: [], text: "call it api")))
        #expect(parse("chief.answer", ["choices": ["4 GB", 3]]) == .failure(.invalid("choices")))
        #expect(parse("chief.answer", ["choices": ["  "]]) == .failure(.invalid("choices")))
        #expect(parse("chief.answer", ["choices": 4]) == .failure(.invalid("choices")))
        #expect(parse("chief.answer", ["choices": Array(repeating: "x", count: 21)]) == .failure(.tooLong("choices")))
        #expect(parse("chief.answer", ["choices": [String(repeating: "x", count: 201)]]) == .failure(.tooLong("choices")))
        #expect(parse("chief.answer", ["text": " "]) == .failure(.invalid("text")))
        #expect(parse("chief.answer", ["text": true]) == .failure(.invalid("text")))
        #expect(parse("chief.answer", ["message": 7]) == .failure(.invalid("message")))
    }

    @Test func approveAndDebugAnswerOnlyInDebugBuilds() {
        // A release build refuses `chief.approve`: any local socket client, the Chief's own shell
        // included, could otherwise answer the cards that gate the Chief's commands.
        #expect(!ChiefControlRequest.isAvailable("chief.approve", debugBuild: false))
        #expect(!ChiefControlRequest.isAvailable("chief.debug", debugBuild: false))
        #expect(ChiefControlRequest.isAvailable("chief.approve", debugBuild: true))
        #expect(ChiefControlRequest.isAvailable("chief.debug", debugBuild: true))
        // Question cards too: they confirm what the Chief creates (a Cloud machine).
        #expect(!ChiefControlRequest.isAvailable("chief.answer", debugBuild: false))
        #expect(ChiefControlRequest.isAvailable("chief.answer", debugBuild: true))
        for method in ["chief.open", "chief.send", "chief.status", "chief.conversations", "chief.read", "chief.mark_read", "chief.stop"] {
            #expect(ChiefControlRequest.isAvailable(method, debugBuild: false), "\(method)")
        }
        #expect(ChiefControlRequest.isDebugBuild) // tests build DEBUG
    }

    @Test func openTargetsWindowThenWorkspace() {
        #expect(parse("chief.open") == .success(.open(target: ChiefControlWindowTarget(windowID: nil, workspaceID: nil))))
        #expect(parse("chief.open", ["window_id": "window:2", "workspace_id": "ABC"])
            == .success(.open(target: ChiefControlWindowTarget(windowID: "window:2", workspaceID: "ABC"))))
        #expect(parse("chief.open", ["window_id": 3]) == .failure(.invalid("window_id")))
    }

    @Test func sendAsUserTrimsText() {
        #expect(parse("chief.send", ["text": "  hi Chief \n"])
            == .success(.send(text: "hi Chief", conversation: nil, from: nil, startTurn: true, clientMessageID: nil)))
        #expect(parse("chief.send", ["text": "hi", "client_message_id": "ios-1"])
            == .success(.send(text: "hi", conversation: nil, from: nil, startTurn: true, clientMessageID: "ios-1")))
    }

    @Test func sendFromAgentDefaultsToStartingATurn() {
        #expect(parse("chief.send", ["text": "done", "from": "Build Bot", "conversation": "conv_a"])
            == .success(.send(text: "done", conversation: "conv_a", from: "Build Bot", startTurn: true, clientMessageID: nil)))
        #expect(parse("chief.send", ["text": "done", "from": "Build Bot", "start_turn": false])
            == .success(.send(text: "done", conversation: nil, from: "Build Bot", startTurn: false, clientMessageID: nil)))
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
        #expect(parse("chief.read") == .success(.read(conversation: nil, beforeSeq: nil, limit: 20)))
        #expect(parse("chief.read", ["limit": 5, "conversation": "conv_b"]) == .success(.read(conversation: "conv_b", beforeSeq: nil, limit: 5)))
        #expect(parse("chief.read", ["limit": 10_000]) == .success(.read(conversation: nil, beforeSeq: nil, limit: 200)))
        #expect(parse("chief.read", ["before_seq": 18, "limit": 4]) == .success(.read(conversation: nil, beforeSeq: 18, limit: 4)))
        #expect(parse("chief.read", ["before_seq": 0]) == .failure(.invalid("before_seq")))
        #expect(parse("chief.read", ["limit": 0]) == .failure(.invalid("limit")))
        #expect(parse("chief.read", ["limit": 1.5]) == .failure(.invalid("limit")))
        #expect(parse("chief.read", ["limit": true]) == .failure(.invalid("limit")))
    }

    @Test func readAfterRequiresAnExclusiveCursorWait() {
        #expect(parse("chief.read", ["after_seq": 7, "wait_for_change": true])
            == .success(.readAfter(conversation: nil, afterSeq: 7, limit: 20)))
        #expect(parse("chief.read", ["after_seq": 7, "after_cursor": "cursor-1", "wait_for_change": true])
            == .success(.readAfter(conversation: nil, afterSeq: 7, limit: 20, afterCursor: "cursor-1")))
        #expect(parse("chief.read", ["after_seq": 0, "wait_for_change": true, "limit": 500])
            == .success(.readAfter(conversation: nil, afterSeq: 0, limit: 200)))
        #expect(parse("chief.read", ["after_seq": 7]) == .failure(.invalid("after_seq")))
        #expect(parse("chief.read", ["wait_for_change": true]) == .failure(.invalid("after_seq")))
        #expect(parse("chief.read", ["after_seq": 7, "before_seq": 2, "wait_for_change": true])
            == .failure(.invalid("after_seq")))
        #expect(parse("chief.read", ["after_seq": -1, "wait_for_change": true])
            == .failure(.invalid("after_seq")))
        #expect(parse("chief.read", ["after_cursor": "cursor-1"]) == .failure(.invalid("after_cursor")))
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
        #expect(parse("chief.debug", ["action": "open-settings"]) == .success(.debug(.openSettings, conversation: nil)))
        #expect(parse("chief.debug", ["action": "close_settings"]) == .success(.debug(.closeSettings, conversation: nil)))
        #expect(parse("chief.debug", ["action": "open-memory"]) == .success(.debug(.openMemory, conversation: nil)))
        #expect(parse("chief.debug", ["action": "close-memory"]) == .success(.debug(.closeMemory, conversation: nil)))
        #expect(parse("chief.debug", ["action": "expand-tools", "conversation": "conv_c"])
            == .success(.debug(.expandTools, conversation: "conv_c")))
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

    @Test func conversationRowsUseTheAuthoritativeInboxOnColdStart() throws {
        let me = Participant(id: .init("me"), kind: .human, displayName: "You")
        let chief = Participant(id: .init("agent_chief"), kind: .agent, displayName: "Chief", agentClass: .chief)
        let id = ConversationID("conv_chief")
        let date = Date(timeIntervalSince1970: 100)
        let summary = ConversationSummary(id: id, participants: [me, chief], createdAt: date, updatedAt: date,
                                          pinRank: 0)
        let inbox = InboxSnapshot(me: me, conversations: [summary], rev: 1)

        // The HomeStore is still empty in this state; the control response is
        // derived from the owner's inbox snapshot instead.
        let rows = ChiefService.controlRows(from: inbox, previews: [id: "Ask Chief anything"], working: [id])
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.id == id.rawValue)
        #expect(row.title == "Chief")
        #expect(row.preview == "Ask Chief anything")
        #expect(row.pinned)
        #expect(row.working)
    }
}
