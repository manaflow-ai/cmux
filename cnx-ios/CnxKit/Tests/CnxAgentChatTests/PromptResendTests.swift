import Foundation
import Testing
@testable import CnxAgentChat

/// Live recheck (2026-10-20): after a link drop, a prompt the Mac already ran came back into
/// the composer, and Send would have run it twice. A prompt keeps one id across a resend
/// (acpmux runs each `promptId` once), and a returned draft goes away once the Mac shows it ran.
@MainActor
@Suite struct PromptResendTests {
    final class Recorder: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "codex", agentName: "Codex", cwd: "~", workspaceTitle: "w", macName: "m")
        var sent: [AgentClientIntent] = []
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) { sent.append(intent) }
    }

    static func prompt(_ intent: AgentClientIntent?) -> (text: String, id: String, resend: Bool)? {
        guard case .prompt(let text, _, _, let id, let resend)? = intent else { return nil }
        return (text, id, resend)
    }

    @Test func aReturnedPromptSentAgainKeepsItsID() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let first = try #require(Self.prompt(source.sent.last))
        #expect(!first.resend)
        // The link dropped before the reply: the draft comes back with its id.
        store.apply(.promptNotSent(text: "run the tests", attachments: [], promptID: first.id, reason: "link down"))
        #expect(store.returnedDraft?.promptID == first.id)
        store.returnedDraft = nil // the composer took it
        store.send(prompt: "run the tests")
        let again = try #require(Self.prompt(source.sent.last))
        #expect(again.id == first.id)
        #expect(again.resend)
        // A new prompt gets a new id.
        store.send(prompt: "something else")
        #expect(Self.prompt(source.sent.last)?.id != first.id)
    }

    @Test func anEditedDraftIsANewPrompt() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let first = try #require(Self.prompt(source.sent.last))
        store.apply(.promptNotSent(text: "run the tests", attachments: [], promptID: first.id, reason: "link down"))
        store.returnedDraft = nil
        store.send(prompt: "run the unit tests")
        #expect(Self.prompt(source.sent.last)?.id != first.id)
    }

    @Test func aDraftTheMacRanIsWithdrawn() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let first = try #require(Self.prompt(source.sent.last))
        store.apply(.promptNotSent(text: "run the tests", attachments: [], promptID: first.id, reason: "link down"))
        store.returnedDraft = nil
        // The replayed transcript shows the Mac ran it.
        store.apply(.userMessage(text: "run the tests", promptId: first.id, turnId: "t1", attachments: [], at: Date()))
        #expect(store.withdrawnDraft?.text == "run the tests")
        // Nothing is left to resend under that id.
        store.send(prompt: "run the tests")
        let again = try #require(Self.prompt(source.sent.last))
        #expect(again.id != first.id)
        #expect(!again.resend)
    }
}
