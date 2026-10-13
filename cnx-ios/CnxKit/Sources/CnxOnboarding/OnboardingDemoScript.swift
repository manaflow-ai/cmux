#if os(iOS) && DEBUG
import CnxDesign
import Foundation

/// DEBUG-only (`-cnx-demo onboarding`, signed out with `CNX_CLEAR_AUTH=1
/// CNX_MOCK_AUTH=1` and setup not complete): Welcome, the email sheet, the
/// email typed and sent, the six-digit code typed (the mock accepts 424242),
/// then setup (team pick, notifications "Not now") into the shell. Each step
/// goes through the screen's own action. Pauses pace the recording.
@MainActor
enum OnboardingDemoScript {
    private static var started = false

    static var isRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-cnx-demo"), index + 1 < arguments.count else { return false }
        return arguments[index + 1] == "onboarding"
    }

    static func start() {
        guard !started else { return }
        started = true
        // Not tied to the welcome screen's lifetime: it runs on into setup.
        Task { @MainActor in await run() }
    }

    private static func run() async {
        let director = DemoDirector.shared
        func step(_ command: DemoDirector.Command, then seconds: Double) async {
            director.post(command)
            try? await Task.sleep(for: .seconds(seconds))
        }
        try? await Task.sleep(for: .seconds(2.6))
        await step(.onboardingOpenEmail, then: 1.6)
        await step(.onboardingTypeEmail("aziz@cmux.dev"), then: 1.6)
        await step(.onboardingSendCode, then: 1.8)
        await step(.onboardingTypeCode("424242"), then: 3.0)
        await step(.setupPickTeam(index: 0), then: 2.2)
        await step(.setupNotNow, then: 2.0)
    }
}
#endif
