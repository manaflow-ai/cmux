import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the resume decision core: the full skip-reason matrix
/// (unsupported agent, no session, unproven session), breadcrumb gating on the
/// inject flag, and never resuming something it shouldn't.
@Suite struct WorkspaceResumePlannerTests {

    private func context(
        name: String = "Fix auth bug",
        kind: RestorableAgentKind? = .claude,
        session: String? = "sess-123",
        proven: Bool = true
    ) -> ResumeWorkspaceContext {
        ResumeWorkspaceContext(
            workspaceName: name,
            agentKind: kind,
            sessionId: session,
            isResumeBindingProven: proven
        )
    }

    @Test func provenClaudeResumesWithBreadcrumbWhenEnabled() {
        let planner = WorkspaceResumePlanner(injectBreadcrumb: true)
        let decision = planner.decide(context(name: "last30days release", kind: .claude))
        guard case .resume(let breadcrumb) = decision else {
            Issue.record("expected resume, got \(decision)")
            return
        }
        #expect(breadcrumb?.contains("last30days release") == true)
    }

    @Test func provenCodexResumesWithBreadcrumb() {
        let planner = WorkspaceResumePlanner(injectBreadcrumb: true)
        #expect(planner.decide(context(kind: .codex)) == .resume(
            breadcrumb: ResumeBreadcrumbBuilder.breadcrumb(workspaceName: "Fix auth bug", agent: .codex)
        ))
    }

    @Test func breadcrumbOmittedWhenInjectionDisabled() {
        let planner = WorkspaceResumePlanner(injectBreadcrumb: false)
        #expect(planner.decide(context()) == .resume(breadcrumb: nil))
    }

    @Test func missingSessionIdSkips() {
        let planner = WorkspaceResumePlanner(injectBreadcrumb: true)
        #expect(planner.decide(context(session: nil)) == .skip(.noSessionId))
        #expect(planner.decide(context(session: "   ")) == .skip(.noSessionId))
    }

    @Test func unprovenSessionSkips() {
        let planner = WorkspaceResumePlanner(injectBreadcrumb: true)
        #expect(planner.decide(context(proven: false)) == .skip(.unprovenSession))
    }

    @Test func unsupportedAgentSkips() {
        let planner = WorkspaceResumePlanner(injectBreadcrumb: true)
        #expect(planner.decide(context(kind: .gemini)) == .skip(.unsupportedAgent(.gemini)))
        #expect(planner.decide(context(kind: nil)) == .skip(.unsupportedAgent(.custom("unknown"))))
    }

    @Test func unsupportedAgentCheckedBeforeSession() {
        // An unsupported agent with no session reports the agent reason, not session.
        let planner = WorkspaceResumePlanner(injectBreadcrumb: true)
        #expect(planner.decide(context(kind: .amp, session: nil)) == .skip(.unsupportedAgent(.amp)))
    }

    @Test func planPartitionsMixedFleet() {
        let planner = WorkspaceResumePlanner(injectBreadcrumb: false)
        let result = planner.plan([
            context(name: "A", kind: .claude, session: "s1", proven: true),
            context(name: "B", kind: .codex, session: "s2", proven: true),
            context(name: "C", kind: .claude, session: nil, proven: true),
            context(name: "D", kind: .gemini, session: "s4", proven: true),
            context(name: "E", kind: .claude, session: "s5", proven: false),
        ])
        #expect(result.resume.count == 2)
        #expect(result.skipped.count == 3)
        let skipReasons = Set(result.skipped.map { $0.1 })
        #expect(skipReasons.contains(.noSessionId))
        #expect(skipReasons.contains(.unsupportedAgent(.gemini)))
        #expect(skipReasons.contains(.unprovenSession))
    }
}
