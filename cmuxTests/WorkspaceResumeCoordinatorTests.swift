import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the resume coordinator: live agents get the breadcrumb
/// directly, dead agents get a native resume first, breadcrumb injection is
/// gated, and non-resumable surfaces are never touched.
@MainActor
@Suite struct WorkspaceResumeCoordinatorTests {

    final class FakeSurface: ResumableWorkspaceSurface {
        var resumeWorkspaceName: String
        var resumeAgentKind: RestorableAgentKind?
        var resumeSessionToken: String?
        var isResumeBindingProven: Bool
        var isAgentLive: Bool

        private(set) var nativeResumeCount = 0
        private(set) var deliveredBreadcrumbs: [String] = []

        init(
            name: String = "Fix auth bug",
            kind: RestorableAgentKind? = .claude,
            session: String? = "claude --resume sess-1",
            proven: Bool = true,
            live: Bool = true
        ) {
            self.resumeWorkspaceName = name
            self.resumeAgentKind = kind
            self.resumeSessionToken = session
            self.isResumeBindingProven = proven
            self.isAgentLive = live
        }

        func runNativeResume() { nativeResumeCount += 1 }
        func deliverResumeBreadcrumb(_ text: String) { deliveredBreadcrumbs.append(text) }
    }

    @Test func liveAgentGetsBreadcrumbWithoutNativeResume() {
        let surface = FakeSurface(live: true)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).resume(surface)
        #expect(outcome == .resumed(deliveredBreadcrumb: true))
        #expect(surface.nativeResumeCount == 0)
        #expect(surface.deliveredBreadcrumbs.count == 1)
        #expect(surface.deliveredBreadcrumbs.first?.contains("Fix auth bug") == true)
    }

    @Test func deadAgentGetsNativeResumeThenBreadcrumb() {
        let surface = FakeSurface(live: false)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).resume(surface)
        #expect(outcome == .resumed(deliveredBreadcrumb: true))
        #expect(surface.nativeResumeCount == 1)
        #expect(surface.deliveredBreadcrumbs.count == 1)
    }

    @Test func breadcrumbOmittedWhenInjectionDisabledButStillResumes() {
        let surface = FakeSurface(live: false)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: false).resume(surface)
        #expect(outcome == .resumed(deliveredBreadcrumb: false))
        #expect(surface.nativeResumeCount == 1)
        #expect(surface.deliveredBreadcrumbs.isEmpty)
    }

    @Test func unsupportedAgentIsSkippedAndUntouched() {
        let surface = FakeSurface(kind: .gemini)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).resume(surface)
        #expect(outcome == .skipped(.unsupportedAgent(.gemini)))
        #expect(surface.nativeResumeCount == 0)
        #expect(surface.deliveredBreadcrumbs.isEmpty)
    }

    @Test func unprovenBindingIsSkipped() {
        let surface = FakeSurface(proven: false)
        #expect(WorkspaceResumeCoordinator(injectBreadcrumb: true).resume(surface) == .skipped(.unprovenSession))
        #expect(surface.nativeResumeCount == 0)
    }

    @Test func missingSessionIsSkipped() {
        let surface = FakeSurface(session: nil)
        #expect(WorkspaceResumeCoordinator(injectBreadcrumb: true).resume(surface) == .skipped(.noSessionId))
    }

    @Test func canResumeReflectsDecision() {
        let coordinator = WorkspaceResumeCoordinator(injectBreadcrumb: false)
        #expect(coordinator.canResume(FakeSurface()))
        #expect(!coordinator.canResume(FakeSurface(kind: .gemini)))
        #expect(!coordinator.canResume(FakeSurface(session: nil)))
    }

    // MARK: - Verification-gated recovery (U11)

    /// A surface that can report the on-disk verification facts the gate needs.
    final class VerifiableFakeSurface: ResumableWorkspaceSurface {
        var resumeWorkspaceName: String
        var resumeAgentKind: RestorableAgentKind?
        var resumeSessionToken: String?
        var isResumeBindingProven: Bool
        var isAgentLive: Bool
        var resumeCwd: String?
        var resumeTranscriptPath: String?
        var transcriptExistsAtWindowCwd: Bool
        var transcriptExistsElsewhere: Bool

        private(set) var nativeResumeCount = 0
        private(set) var deliveredBreadcrumbs: [String] = []
        private(set) var deliveredHonestPrompts: [String] = []

        init(
            name: String = "Fix order-to-go CLI",
            kind: RestorableAgentKind? = .claude,
            session: String? = "claude --resume sess-1",
            live: Bool = false,
            cwd: String? = "/Users/me/repo",
            transcriptPath: String? = "/Users/me/.claude/projects/-Users-me-repo/sess-1.jsonl",
            atWindowCwd: Bool = true,
            elsewhere: Bool = false
        ) {
            self.resumeWorkspaceName = name
            self.resumeAgentKind = kind
            self.resumeSessionToken = session
            self.isResumeBindingProven = true
            self.isAgentLive = live
            self.resumeCwd = cwd
            self.resumeTranscriptPath = transcriptPath
            self.transcriptExistsAtWindowCwd = atWindowCwd
            self.transcriptExistsElsewhere = elsewhere
        }

        func runNativeResume() { nativeResumeCount += 1 }
        func deliverResumeBreadcrumb(_ text: String) { deliveredBreadcrumbs.append(text) }
        func deliverHonestRecoveryPrompt(_ text: String) { deliveredHonestPrompts.append(text) }
    }

    @Test func recoverVerifiedBindingResumesAndKeepsBreadcrumbPrivacySafe() {
        let surface = VerifiableFakeSurface(live: false, atWindowCwd: true)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).recover(surface)
        #expect(outcome == .resumed(deliveredBreadcrumb: true))
        #expect(surface.nativeResumeCount == 1)
        #expect(surface.deliveredBreadcrumbs.first?.contains("sess-1.jsonl") == false)
        #expect(surface.deliveredHonestPrompts.isEmpty)
    }

    @Test func recoverCwdMismatchDeliversHonestPromptAndNeverResumes() {
        // Transcript exists only elsewhere -> the anti-Example-3 mis-attribution.
        let surface = VerifiableFakeSurface(atWindowCwd: false, elsewhere: true)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).recover(surface)
        #expect(outcome == .honestRecovery(reason: .cwdMismatch))
        #expect(surface.nativeResumeCount == 0)
        #expect(surface.deliveredBreadcrumbs.isEmpty)
        #expect(surface.deliveredHonestPrompts.count == 1)
        #expect(surface.deliveredHonestPrompts.first?.contains("/Users/me/repo") == true)
        #expect(surface.deliveredHonestPrompts.first?.contains("sess-1") == false)
    }

    @Test func recoverMissingTranscriptDeliversHonestPrompt() {
        let surface = VerifiableFakeSurface(atWindowCwd: false, elsewhere: false)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).recover(surface)
        #expect(outcome == .honestRecovery(reason: .transcriptMissing))
        #expect(surface.nativeResumeCount == 0)
    }

    @Test func recoverUnwiredSurfaceDefaultsToHonestRecovery() {
        // The v1 FakeSurface does not implement the verification facts, so the
        // conservative defaults route it to honest recovery — never a blind
        // auto-resume of an unverified binding.
        let surface = FakeSurface(live: false)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).recover(surface)
        guard case .honestRecovery = outcome else {
            Issue.record("expected honestRecovery for an unwired surface, got \(outcome)")
            return
        }
        #expect(surface.nativeResumeCount == 0)
    }

    @Test func recoverLiveVerifiedAgentSkipsNativeResume() {
        let surface = VerifiableFakeSurface(live: true, atWindowCwd: true)
        let outcome = WorkspaceResumeCoordinator(injectBreadcrumb: true).recover(surface)
        #expect(outcome == .resumed(deliveredBreadcrumb: true))
        #expect(surface.nativeResumeCount == 0)
        #expect(surface.deliveredBreadcrumbs.count == 1)
    }
}
