import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the window↔session binding *consumption* contract (U9/R12):
/// the facts a restored panel contributes are its OWN — two concurrent panels
/// produce distinct, non-crossed bindings (anti-Example-1), and a panel with no
/// agent produces no binding. (The hook-capture coverage defect itself — only
/// some panes recording a session — is pinned by the U14 live loop; this covers
/// the contract the verification gate consumes.)
@MainActor
@Suite struct WindowSessionBindingTests {

    final class BindingFakeSurface: ResumableWorkspaceSurface {
        var resumeWorkspaceName: String
        var resumeAgentKind: RestorableAgentKind?
        var resumeSessionToken: String?
        var isResumeBindingProven: Bool = true
        var isAgentLive: Bool = false
        var resumeCwd: String?
        var resumeTranscriptPath: String?
        var transcriptExistsAtWindowCwd: Bool
        var transcriptExistsElsewhere: Bool = false

        init(
            name: String,
            kind: RestorableAgentKind?,
            session: String?,
            cwd: String?,
            transcriptPath: String? = nil,
            atWindowCwd: Bool = true
        ) {
            self.resumeWorkspaceName = name
            self.resumeAgentKind = kind
            self.resumeSessionToken = session
            self.resumeCwd = cwd
            self.resumeTranscriptPath = transcriptPath
            self.transcriptExistsAtWindowCwd = atWindowCwd
        }

        func runNativeResume() {}
        func deliverResumeBreadcrumb(_ text: String) {}
        func deliverHonestRecoveryPrompt(_ text: String) {}
    }

    private let coordinator = WorkspaceResumeCoordinator(injectBreadcrumb: true)

    @Test func panelRecordsItsOwnSessionCwdAndKind() {
        // Covers R12: the facts carry this panel's own session id, cwd, and kind.
        let surface = BindingFakeSurface(
            name: "Fix order-to-go CLI",
            kind: .claude,
            session: "claude --resume sess-A",
            cwd: "/Users/me/ordertogo"
        )
        let facts = coordinator.bindingFacts(for: surface)
        let context = coordinator.recoveryContext(for: surface)
        #expect(facts.hasBinding)
        #expect(facts.agentKind == .claude)
        #expect(facts.sessionId == "sess-A")
        #expect(context.cwd == "/Users/me/ordertogo")
        #expect(context.workspaceName == "Fix order-to-go CLI")
    }

    @Test func twoConcurrentPanelsProduceDistinctNonCrossedBindings() {
        // Anti-Example-1: panel A's facts must not bleed into panel B's.
        let a = BindingFakeSurface(
            name: "ordertogo", kind: .claude, session: "sess-A", cwd: "/Users/me/ordertogo"
        )
        let b = BindingFakeSurface(
            name: "x-money-research", kind: .codex, session: "sess-B", cwd: "/Users/me/x-money"
        )
        let fa = coordinator.bindingFacts(for: a)
        let fb = coordinator.bindingFacts(for: b)
        #expect(fa.sessionId == "sess-A")
        #expect(fb.sessionId == "sess-B")
        #expect(fa.sessionId != fb.sessionId)
        #expect(coordinator.recoveryContext(for: a).cwd != coordinator.recoveryContext(for: b).cwd)
        #expect(fa.agentKind != fb.agentKind)
    }

    @Test func panelWithNoAgentRecordsNoBinding() {
        // A pane that never had an agent has no binding -> hasBinding == false,
        // routing it to honest recovery rather than a guess.
        let surface = BindingFakeSurface(name: "[no agent]", kind: nil, session: nil, cwd: "/Users/me")
        let facts = coordinator.bindingFacts(for: surface)
        #expect(facts.hasBinding == false)
        #expect(coordinator.router.gate.verify(facts) == .unverified(.noBinding))
    }

    @Test func panelWithSessionButNoKindStillHasBinding() {
        // A resume token alone (kind not yet resolved) is still a binding; the
        // gate refines it (unsupported/agent) rather than dropping it as "no binding".
        let surface = BindingFakeSurface(name: "w", kind: nil, session: "claude --resume sess-C", cwd: "/Users/me")
        let facts = coordinator.bindingFacts(for: surface)
        #expect(facts.hasBinding == true)
        #expect(facts.sessionId == "sess-C")
    }
}
