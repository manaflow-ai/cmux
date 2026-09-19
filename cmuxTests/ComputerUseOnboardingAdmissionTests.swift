import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Computer Use onboarding admission")
struct ComputerUseOnboardingAdmissionTests {
    @Test func completionAfterDisableCannotAuthorizeTheNextEnable() {
        var phase = ComputerUseRuntimePermissionPhase.disabled(onboardingComplete: false)
        phase = phase.applying(.setEnabled(true))
        phase = phase.applying(.onboardingPresented)
        phase = phase.applying(.setEnabled(false))

        // A capture response can arrive after the user disables Computer Use.
        // That obsolete response must not become consent for a later launch.
        phase = phase.applying(.onboardingCompleted)
        #expect(phase == .disabled(onboardingComplete: false))
        #expect(phase.applying(.setEnabled(true)) == .onboardingRequired)
    }
}
