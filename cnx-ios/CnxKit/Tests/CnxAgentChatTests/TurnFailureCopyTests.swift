import Foundation
import Testing
@testable import CnxAgentChat

/// A failed turn's card says why in plain words (the Mac's failureCopy), with the agent's own
/// message under Details; the cmux model service's refusals get their own sentence.
@Suite struct TurnFailureCopyTests {
    static let routerForbidden = #"API Error: 403 {"error":{"code":"auth.forbidden","message":"this team cannot use the model router on this deployment yet","type":"invalid_request_error"}}"#

    @Test func cmuxModelServiceRefusalIsPlain() {
        let copy = TurnFailureCopy(message: Self.routerForbidden, harness: "cmux", harnessName: "Cmux")
        #expect(copy.kind == .modelServiceUnavailable)
        #expect(copy.sentence == "cmux's model service isn't available for this team yet.")
        #expect(copy.detail == Self.routerForbidden)
        // Same refusal, harness unknown: the message names the router.
        #expect(TurnFailureCopy(message: Self.routerForbidden).kind == .modelServiceUnavailable)
        let machine = #"API Error: 403 {"error":{"code":"auth.forbidden","message":"machine installs cannot use the model router yet"}}"#
        #expect(TurnFailureCopy(message: machine, harness: "cmux").sentence == "cmux's model service isn't available here yet.")
    }

    @Test func relayErrorsSayWhatToDo() {
        let notConnected = #"API Error: 503 {"error":{"code":"router.no_upstream","message":"the cmux model router is not connected; open cmux"}}"#
        #expect(TurnFailureCopy(message: notConnected, harness: "cmux").kind == .modelServiceNotConnected)
        let expired = #"API Error: 503 {"error":{"code":"router.upstream_expired","message":"the cmux model router sign-in expired; open cmux to renew it"}}"#
        #expect(TurnFailureCopy(message: expired, harness: "cmux").kind == .modelServiceExpired)
        let unreachable = #"API Error: 502 {"error":{"code":"router.unreachable","message":"the cmux model router did not answer"}}"#
        #expect(TurnFailureCopy(message: unreachable, harness: "cmux").kind == .modelServiceUnreachable)
    }

    @Test func macKindsCarryOver() {
        #expect(TurnFailureCopy(message: "API Error: 429 rate_limit_error", harness: "claude", harnessName: "Claude").sentence
            == "Claude is rate limited or out of capacity. Try again in a moment, or switch model.")
        #expect(TurnFailureCopy(message: "Unable to connect to API (ECONNREFUSED)", harness: "claude", harnessName: "Claude").kind == .unreachable)
        #expect(TurnFailureCopy(message: "Invalid API key · Please run /login", harness: "claude").kind == .subscriptionLogin)
        #expect(TurnFailureCopy(message: "API Error: 401 unauthorized", harness: "claude-sr", harnessName: "Claude").sentence
            == "subrouter refused Claude’s request (401). Check that route’s key or account.")
        #expect(TurnFailureCopy(message: "trust.pending: answer the trust question").kind == .trustPending)
    }

    @Test func otherErrorsReadTheInnerMessage() {
        let copy = TurnFailureCopy(message: #"API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long"}}"#)
        #expect(copy.kind == .other && copy.sentence == "Prompt is too long.")
        #expect(copy.detail != nil)
        // Plain text stays as it is, with no Details.
        let plain = TurnFailureCopy(message: "agent process closed")
        #expect(plain.sentence == "agent process closed" && plain.detail == nil)
        #expect(TurnFailureCopy(message: nil).sentence == "The turn ended with an error.")
    }

    @MainActor @Test func retryShowsWhileTheTurnRuns() {
        final class Silent: AgentSessionSource {
            let summary = AgentSessionSummary(id: "s", name: "S", harness: "cmux", agentName: "Cmux", cwd: "~", workspaceTitle: "w", macName: "m")
            func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
            func send(_ intent: AgentClientIntent) {}
        }
        let store = AgentChatStore(source: Silent())
        store.apply(.userMessage(text: "hi", promptId: "p", turnId: "t", attachments: [], at: Date()))
        store.apply(.turnStarted(turnId: "t", at: Date()))
        store.apply(.retrying(attempt: 2, maxAttempts: 10, status: 503))
        #expect(store.turns.last?.retry?.label == "Retrying (2 of 10, error 503)")
        store.apply(.turnResult(turnId: "t", status: .failed, errorText: Self.routerForbidden, at: Date()))
        #expect(store.turns.last?.retry == nil && store.turns.last?.status == .failed)
        // A retry after the turn ended changes nothing.
        store.apply(.retrying(attempt: 3, maxAttempts: 10, status: nil))
        #expect(store.turns.last?.retry == nil)
    }
}
