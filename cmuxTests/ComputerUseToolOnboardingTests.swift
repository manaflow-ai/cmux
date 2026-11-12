import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Computer Use first-tool onboarding")
@MainActor
struct ComputerUseToolOnboardingTests {
    @Test(arguments: [
        "cmux-cua.get_app_state",
        "mcp__cmux-cua__get_screen_size",
        "mcp__cmux_cua__click",
        "cmux_cua.screenshot"
    ])
    func firstFunctionalToolOpensSetupWithoutAdmittingTools(_ tool: String) async throws {
        let fixture = try ComputerUseToolOnboardingFixture()
        defer { fixture.remove() }
        try await fixture.enable()
        #expect(fixture.presentations.isEmpty)

        await fixture.send(tool)

        #expect(fixture.presentations == [.overview])
        #expect(fixture.runtime.permissionPhase == .onboarding)
        #expect(!fixture.runtime.onboardingIsComplete)
    }

    @Test func firstFunctionalToolOpensSetupBeforeLiveSessionProjection() async throws {
        let fixture = try ComputerUseToolOnboardingFixture(hasLiveSession: false)
        defer { fixture.remove() }
        try await fixture.enable()

        await fixture.send("mcp__cmux_cua__get_app_state")

        #expect(fixture.presentations == [.overview])
        #expect(fixture.runtime.permissionPhase == .onboarding)
        #expect(!fixture.runtime.onboardingIsComplete)
    }

    @Test func firstFunctionalToolEnablesComputerUseWhenToggleIsOff() async throws {
        let fixture = try ComputerUseToolOnboardingFixture()
        defer { fixture.remove() }
        await fixture.runtime.setEnabled(false)

        await fixture.send("mcp__cmux_cua__get_app_state")

        #expect(fixture.runtime.desiredEnabled)
        #expect(fixture.presentations == [.overview])
        #expect(fixture.runtime.permissionPhase == .onboarding)
    }

    @Test func retriesStayQuietAndSettingsCanResumeSetup() async throws {
        let fixture = try ComputerUseToolOnboardingFixture()
        defer { fixture.remove() }
        try await fixture.enable()
        await fixture.send("cmux-cua.get_app_state")
        await fixture.send("cmux-cua.get_app_state")
        await fixture.send(nil, hook: .stop)
        await fixture.send("cmux-cua.click")
        #expect(fixture.presentations == [.overview])

        #expect(fixture.coordinator.presentOnboardingFromSettings(startingAt: .screenRecording))
        #expect(fixture.presentations == [.overview, .screenRecording])
        #expect(!fixture.runtime.onboardingIsComplete)
    }

    @Test func startupDiscoveryAndPermissionProbesDoNotOpenSetup() async throws {
        let fixture = try ComputerUseToolOnboardingFixture()
        defer { fixture.remove() }
        try await fixture.enable()
        await fixture.send(nil, hook: .sessionStart)
        await fixture.send(nil, hook: .userPromptSubmit)
        await fixture.send("Skill")
        await fixture.send("Bash")
        await fixture.send("cmux-cua.get_app_state", hook: .postToolUseFailure)
        for prefix in ["mcp__cmux-cua__", "mcp__cmux_cua__", "cmux-cua.", "cmux_cua."] {
            await fixture.send(prefix + "check_permissions")
            await fixture.send(prefix)
        }
        #expect(fixture.presentations.isEmpty)
        #expect(fixture.runtime.permissionPhase == .onboardingRequired)
    }

    @Test func staleOrUnownedSessionDoesNotOpenSetup() async throws {
        let fixture = try ComputerUseToolOnboardingFixture()
        defer { fixture.remove() }
        try await fixture.enable()
        await fixture.send("cmux-cua.get_app_state", surface: UUID())
        #expect(fixture.presentations.isEmpty)
        #expect(fixture.runtime.permissionPhase == .onboardingRequired)
    }

    @Test func explicitToolRequestEnablesComputerUseEvenWhenMenuFeatureIsOff() async throws {
        let fixture = try ComputerUseToolOnboardingFixture()
        defer { fixture.remove() }
        try await fixture.enable()
        fixture.featureEnabled = false
        await fixture.send("cmux-cua.get_app_state")
        #expect(fixture.presentations == [.overview])
        #expect(fixture.runtime.permissionPhase == .onboarding)
        fixture.featureEnabled = true
        await fixture.runtime.setEnabled(false)
        await fixture.send("cmux-cua.get_app_state")
        #expect(fixture.presentations == [.overview, .overview])
        #expect(fixture.runtime.desiredEnabled)
    }

    @Test func completedSetupStaysQuietUntilHelperInvalidation() async throws {
        let fixture = try ComputerUseToolOnboardingFixture()
        defer { fixture.remove() }
        try await fixture.enable()
        let store = fixture.runtime.onboarding
        store.restore(for: "synthetic-helper-signature")
        _ = store.finishVerification(.ready, attempt: try #require(store.beginVerification()))
        await fixture.send("cmux-cua.get_app_state")
        #expect(fixture.presentations.isEmpty)

        store.invalidateHelper()
        await fixture.send("cmux-cua.get_app_state")
        #expect(fixture.presentations == [.overview])
        #expect(!fixture.runtime.onboardingIsComplete)
    }
}
