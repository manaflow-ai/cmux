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
}
