import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Presentation is an explicit action, never a side effect of observing readiness.
@Suite("Computer Use onboarding intent")
@MainActor
struct ComputerUseOnboardingIntentTests {
    @Test(arguments: [false, true], [false, true])
    func ambientRefreshStaysSilent(accessibility: Bool, screenRecording: Bool) async throws {
        let fixture = try ComputerUseToolOnboardingFixture()
        defer { fixture.remove() }
        let responder = try permissionResponder(fixture, accessibility: accessibility, screenRecording: screenRecording)
        defer { responder.stop() }
        let actions = settingsActions(fixture)

        // Initial Settings rendering, enabled-setting reconciliation, and the
        // refresh on app activation all enter this same host action.
        await actions.refreshComputerUsePermissions()
        try await fixture.enable()
        await actions.refreshComputerUsePermissions()
        await fixture.runtime.setEnabled(true)
        await actions.refreshComputerUsePermissions()

        // TCC callbacks and helper recovery can publish new readiness without
        // granting permission to present a window.
        _ = await fixture.runtime.refreshHelperStatusAfterPermissionChange()
        fixture.runtime.onboarding.statusChanged()
        await actions.refreshComputerUsePermissions()
        fixture.featureEnabled = false
        await actions.refreshComputerUsePermissions()
        fixture.featureEnabled = true
        await actions.refreshComputerUsePermissions()

        #expect(actions.computerUsePermissionStatusIsKnown())
        #expect(actions.computerUseAccessibilityGranted() == accessibility)
        #expect(actions.computerUseScreenRecordingGranted() == screenRecording)
        #expect(!fixture.runtime.onboardingIsComplete)
        #expect(fixture.presentations.isEmpty)
    }

    @Test func dismissedAndCompletedSetupStayQuietUntilExplicitRequest() async throws {
        let fixture = try ComputerUseToolOnboardingFixture()
        defer { fixture.remove() }
        let responder = try permissionResponder(fixture, accessibility: true, screenRecording: true)
        defer { responder.stop() }
        let actions = settingsActions(fixture)
        try await fixture.enable()

        await fixture.send("cmux-cua.get_app_state")
        #expect(fixture.presentations == [.overview])

        // Closing the window leaves the claimed runtime phase intact. Refresh
        // and retries must not reopen that dismissed flow.
        await actions.refreshComputerUsePermissions()
        await fixture.send("cmux-cua.get_app_state")
        await fixture.send(nil, hook: .stop)
        await actions.refreshComputerUsePermissions()
        #expect(fixture.presentations == [.overview])

        actions.finishComputerUseSetup()
        #expect(fixture.presentations == [.overview, .screenRecording])
        let store = fixture.runtime.onboarding
        store.restore(for: "synthetic-intent-helper")
        #expect(store.finishVerification(.ready, attempt: try #require(store.beginVerification())) == .ready)

        await actions.refreshComputerUsePermissions()
        await fixture.send("cmux-cua.get_app_state")
        #expect(fixture.runtime.onboardingIsComplete)
        #expect(fixture.presentations == [.overview, .screenRecording])

        // Replacing the helper invalidates readiness but isn't user intent.
        store.invalidateHelper()
        await actions.refreshComputerUsePermissions()
        #expect(fixture.presentations == [.overview, .screenRecording])
        await fixture.send("cmux-cua.get_app_state")
        #expect(fixture.presentations == [.overview, .screenRecording, .overview])
    }

    @Test(arguments: [false, true])
    func settingsPermissionActionsSelectTheirStep(accessibility: Bool) async throws {
        let fixture = try ComputerUseToolOnboardingFixture()
        defer { fixture.remove() }
        let responder = try permissionResponder(fixture, accessibility: accessibility, screenRecording: true)
        defer { responder.stop() }
        let actions = settingsActions(fixture)
        try await fixture.enable()
        await actions.refreshComputerUsePermissions()
        #expect(fixture.presentations.isEmpty)

        actions.requestComputerUseAccessibility()
        actions.requestComputerUseScreenRecording()
        actions.openComputerUseAccessibilitySettings()
        actions.openComputerUseScreenRecordingSettings()
        actions.finishComputerUseSetup()

        #expect(fixture.presentations == [
            .accessibility, .screenRecording, .accessibility, .screenRecording,
            accessibility ? .screenRecording : .accessibility
        ])
        #expect(!fixture.runtime.onboardingIsComplete)
    }

    @Test func concurrentProtectedRequestsCoalesceAndAmbientEventsStaySilent() async throws {
        let fixture = try ComputerUseToolOnboardingFixture()
        defer { fixture.remove() }
        let responder = try permissionResponder(fixture, accessibility: true, screenRecording: true)
        defer { responder.stop() }
        try await fixture.enable()

        for hook in [WorkstreamEvent.HookEventName.sessionStart, .userPromptSubmit, .stop, .sessionEnd] {
            await fixture.send(nil, hook: hook)
        }
        for tool in ["Skill", "Bash", "Read", "cmux-cua.check_permissions"] {
            await fixture.send(tool)
        }
        #expect(fixture.presentations.isEmpty)

        async let first: Void = fixture.send("cmux-cua.get_app_state")
        async let retry: Void = fixture.send("cmux-cua.get_app_state")
        async let sibling: Void = fixture.send("cmux-cua.screenshot")
        _ = await (first, retry, sibling)
        #expect(fixture.presentations == [.overview])
        #expect(!fixture.runtime.onboardingIsComplete)

        await settingsActions(fixture).refreshComputerUsePermissions()
        #expect(fixture.presentations == [.overview])
    }

    private func settingsActions(_ fixture: ComputerUseToolOnboardingFixture) -> HostSettingsActions {
        HostSettingsActions(
            configFileURL: fixture.persistence.root.appendingPathComponent("cmux.json"),
            computerUseRuntimeService: fixture.runtime,
            browserDataImportCoordinator: BrowserDataImportCoordinator(),
            runComputerUseOnboardingAction: { startingPoint in
                fixture.coordinator.presentOnboardingFromSettings(startingAt: startingPoint)
            }
        )
    }

    private func permissionResponder(
        _ fixture: ComputerUseToolOnboardingFixture,
        accessibility: Bool,
        screenRecording: Bool
    ) throws -> UnixSocketResponder {
        try UnixSocketResponder(
            path: fixture.persistence.paths.daemonSocketURL.path,
            response: """
                {"ok":true,"result":{"structuredContent":{
                "accessibility":\(accessibility),"screen_recording":\(screenRecording),
                "source":{"attribution":"helper-daemon"}}}}
                """.replacingOccurrences(of: "\n", with: "")
        )
    }
}
