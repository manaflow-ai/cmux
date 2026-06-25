import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the agent-first recovery router (U11/R14/R17): a verified
/// binding resumes with a privacy-safe breadcrumb; an unverified one
/// yields an honest cwd-scoped prompt that fabricates no session; the silent
/// path never auto-resumes an unverified binding; and the outcome is always
/// binary (never a session list).
@Suite struct RecoveryRouterTests {

    private func facts(
        hasBinding: Bool = true,
        kind: RestorableAgentKind? = .claude,
        session: String? = "sess-123",
        resumeConstructable: Bool = true,
        atWindowCwd: Bool = true,
        elsewhere: Bool = false
    ) -> ResumeBindingFacts {
        ResumeBindingFacts(
            hasBinding: hasBinding,
            agentKind: kind,
            sessionId: session,
            resumeCommandConstructable: resumeConstructable,
            transcriptExistsAtWindowCwd: atWindowCwd,
            transcriptExistsElsewhere: elsewhere
        )
    }

    private func context(
        name: String = "Fix order-to-go CLI",
        cwd: String? = "/Users/me/repo",
        path: String? = "/Users/me/.claude/projects/-Users-me-repo/sess-123.jsonl"
    ) -> RecoveryContext {
        RecoveryContext(workspaceName: name, cwd: cwd, transcriptPath: path)
    }

    // MARK: - Verified branch

    @Test func verifiedBindingResumesWithPrivacySafeBreadcrumb() {
        let router = RecoveryRouter(injectBreadcrumb: true)
        let action = router.route(facts(), context: context())
        guard case .resumeVerified(let breadcrumb) = action else {
            Issue.record("expected resumeVerified, got \(action)")
            return
        }
        #expect(breadcrumb?.contains("Fix order-to-go CLI") == true)
        #expect(breadcrumb?.contains("sess-123.jsonl") == false)
        // Covers R14: a verified window is told to continue, never to reconstruct-or-ask.
        #expect(breadcrumb?.localizedCaseInsensitiveContains("otherwise ask") != true)
    }

    @Test func verifiedBindingOmitsBreadcrumbWhenInjectionDisabled() {
        let router = RecoveryRouter(injectBreadcrumb: false)
        #expect(router.route(facts(), context: context()) == .resumeVerified(breadcrumb: nil))
    }

    // MARK: - Unverified branch

    @Test func unverifiedBindingYieldsHonestPromptWithNoFabricatedSession() {
        let router = RecoveryRouter(injectBreadcrumb: true)
        // Transcript exists only elsewhere -> cwdMismatch (anti-Example-3).
        let action = router.route(facts(atWindowCwd: false, elsewhere: true), context: context())
        guard case .honestRecovery(let prompt, let reason) = action else {
            Issue.record("expected honestRecovery, got \(action)")
            return
        }
        #expect(reason == .cwdMismatch)
        // Honest: scoped to this window's cwd, no fabricated session id/claim.
        #expect(prompt.contains("/Users/me/repo"))
        #expect(!prompt.contains("sess-123"))
        #expect(prompt.localizedCaseInsensitiveContains("could not verify"))
        #expect(prompt.localizedCaseInsensitiveContains("do not adopt or guess"))
        #expect(!prompt.contains("\n"))
    }

    @Test func noBindingYieldsHonestPromptNotResume() {
        let router = RecoveryRouter(injectBreadcrumb: true)
        let action = router.route(facts(hasBinding: false), context: context(path: nil))
        guard case .honestRecovery(_, let reason) = action else {
            Issue.record("expected honestRecovery, got \(action)")
            return
        }
        #expect(reason == .noBinding)
    }

    @Test func transcriptMissingYieldsHonestRecovery() {
        let router = RecoveryRouter(injectBreadcrumb: true)
        let action = router.route(facts(atWindowCwd: false, elsewhere: false), context: context())
        guard case .honestRecovery(_, let reason) = action else {
            Issue.record("expected honestRecovery, got \(action)")
            return
        }
        #expect(reason == .transcriptMissing)
    }

    // MARK: - Silent-path safety (R14)

    @Test func silentPathNeverAutoResumesUnverified() {
        let router = RecoveryRouter(injectBreadcrumb: true)
        #expect(router.wouldAutoResume(facts(hasBinding: false)) == false)
        #expect(router.wouldAutoResume(facts(atWindowCwd: false, elsewhere: true)) == false)
        #expect(router.wouldAutoResume(facts(atWindowCwd: false, elsewhere: false)) == false)
        #expect(router.wouldAutoResume(facts(session: nil)) == false)
        #expect(router.wouldAutoResume(facts(kind: .gemini)) == false)
        // Only a fully verified binding auto-resumes.
        #expect(router.wouldAutoResume(facts()) == true)
    }

    // MARK: - Binary outcome (R17 — no session picker)

    @Test func outcomeIsAlwaysOneOfTwoBranchesNeverAList() {
        let router = RecoveryRouter(injectBreadcrumb: true)
        let scenarios: [ResumeBindingFacts] = [
            facts(),
            facts(hasBinding: false),
            facts(atWindowCwd: false, elsewhere: true),
            facts(atWindowCwd: false, elsewhere: false),
            facts(session: nil),
            facts(kind: .gemini),
            facts(resumeConstructable: false),
            facts(kind: .codex),
        ]
        for f in scenarios {
            let action = router.route(f, context: context())
            switch action {
            case .resumeVerified, .honestRecovery:
                break // exactly the two allowed shapes
            }
        }
    }

    @Test func honestPromptOmitsCwdClauseWhenCwdUnknown() {
        let router = RecoveryRouter(injectBreadcrumb: true)
        let action = router.route(facts(hasBinding: false), context: context(cwd: nil, path: nil))
        guard case .honestRecovery(let prompt, _) = action else {
            Issue.record("expected honestRecovery, got \(action)")
            return
        }
        #expect(!prompt.localizedCaseInsensitiveContains("working directory is"))
        #expect(prompt.localizedCaseInsensitiveContains("could not verify"))
    }
}
