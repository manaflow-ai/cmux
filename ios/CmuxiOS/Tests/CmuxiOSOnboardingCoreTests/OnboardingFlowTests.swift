@testable import CmuxiOSOnboardingCore
import Testing

@Suite("Onboarding flow")
struct OnboardingFlowTests {
    private let signedOut = OnboardingContext()
    private var signedIn: OnboardingContext { OnboardingContext(isSignedIn: true) }

    @Test("A fresh signed-out run starts at welcome and walks every step in order")
    func freshRunVisitsEveryStep() {
        var flow = OnboardingFlow(context: signedOut)
        #expect(flow.current == .welcome)
        // The Cloud step (C12) shows only when the app offers it.
        #expect(flow.visibleSteps == OnboardingStep.allCases.filter { $0 != .cloudMachine })
        flow.send(.advance)
        flow.send(.advance)
        flow.send(.advance)
        #expect(flow.current == .signIn)
        let blocked = flow.send(.advance)
        #expect(blocked.direction == .none)
        #expect(flow.current == .signIn)
        flow.send(.contextChanged(signedIn))
        var visited: [OnboardingStep] = [flow.current]
        while !flow.isFinished {
            flow.send(.advance)
            if !flow.isFinished { visited.append(flow.current) }
        }
        #expect(visited == [.notifications, .installMac, .localNetwork, .pair, .sshHost, .celebrate])
        #expect(flow.progress.outcomes[.signIn] == .completed)
    }

    @Test("Skip on a tour page lands on sign-in and the tour stops counting")
    func skipIntro() {
        var flow = OnboardingFlow(context: signedOut)
        flow.send(.advance)
        let transition = flow.send(.skipIntro)
        #expect(transition.to == .signIn)
        #expect(transition.direction == .forward)
        #expect(flow.progress.outcomes[.welcome] == .completed)
        #expect(flow.progress.outcomes[.approve] == .skipped)
        #expect(flow.progress.outcomes[.reply] == .skipped)
        // The completed welcome page is still one step back; the skipped pages are not.
        #expect(flow.send(.back).to == .welcome)
        #expect(flow.send(.back).direction == .none)
        #expect(flow.visibleSteps.first == .welcome)
        #expect(!flow.visibleSteps.contains(.approve))
    }

    @Test("Steps whose condition is met are neither shown nor counted")
    func appliesToContext() {
        let context = OnboardingContext(isSignedIn: true, notifications: .granted, localNetwork: .denied, hasTrustedMac: true)
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .signIn), context: context)
        #expect(flow.current == .sshHost)
        #expect(flow.visibleSteps == [.sshHost, .celebrate])
        #expect(flow.position.index == 0)
        #expect(flow.position.total == 2)
        flow.send(.skipStep)
        #expect(flow.current == .celebrate)
        #expect(flow.progress.outcomes[.sshHost] == .skipped)
        #expect(!flow.canSkipStep)
        #expect(!flow.canGoBack)
        let done = flow.send(.advance)
        #expect(done.finished)
        #expect(flow.isFinished)
        #expect(flow.send(.advance).direction == .none)
    }

    @Test("Back stays inside a phase and passes over answered permissions")
    func backRules() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .pair), context: signedIn)
        #expect(flow.current == .pair)
        var context = signedIn
        context.localNetwork = .granted
        flow.send(.contextChanged(context))
        #expect(flow.send(.back).to == .installMac)
        #expect(flow.send(.back).to == .notifications)
        #expect(!flow.canGoBack)
        #expect(flow.send(.back).direction == .none)

        var intro = OnboardingFlow(progress: OnboardingProgress(current: .reply), context: signedOut)
        #expect(intro.send(.back).to == .approve)
        #expect(intro.send(.back).to == .welcome)
        #expect(!intro.canGoBack)
    }

    @Test("Signing out during setup returns to sign-in; signing in resumes setup")
    func signOutMidSetup() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .installMac), context: signedIn)
        let out = flow.send(.contextChanged(signedOut))
        #expect(out.to == .signIn)
        #expect(out.direction == .backward)
        let back = flow.send(.contextChanged(signedIn))
        #expect(back.to == .notifications)
    }

    @Test("Sign-in cannot be skipped and the tour cannot be skipped from setup")
    func skipGuards() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .signIn), context: signedOut)
        #expect(!flow.canSkipStep)
        #expect(flow.send(.skipStep).direction == .none)
        #expect(flow.send(.skipIntro).direction == .none)
        flow.send(.contextChanged(signedIn))
        #expect(flow.send(.skipIntro).direction == .none)
    }

    @Test("Resume: a stored setup step for a signed-out user returns to sign-in")
    func resumeSignedOut() {
        let flow = OnboardingFlow(progress: OnboardingProgress(current: .pair), context: signedOut)
        #expect(flow.current == .signIn)
        #expect(!flow.isFinished)
    }

    @Test("Resume: a stored step that no longer applies moves forward, or finishes")
    func resumeForward() {
        let paired = OnboardingContext(isSignedIn: true, notifications: .granted, hasTrustedMac: true)
        let flow = OnboardingFlow(progress: OnboardingProgress(current: .installMac), context: paired)
        #expect(flow.current == .sshHost)
        let finished = OnboardingFlow(progress: OnboardingProgress(current: .celebrate, finished: true), context: paired)
        #expect(finished.isFinished)
    }

    @Test("Replay shows the tour again, skips sign-in and SSH, and keeps mode across context changes")
    func replay() {
        let context = OnboardingContext(isSignedIn: true, notifications: .granted, hasTrustedMac: true, mode: .replay)
        var flow = OnboardingFlow(progress: OnboardingProgress(outcomes: [.approve: .skipped]), context: context)
        #expect(flow.visibleSteps == [.welcome, .approve, .reply, .celebrate])
        var changed = context
        changed.mode = .firstRun
        flow.send(.contextChanged(changed))
        #expect(flow.context.mode == .replay)
        flow.send(.advance)
        flow.send(.advance)
        #expect(flow.send(.advance).to == .celebrate)
    }

    @Test("A priming step answered elsewhere stays until the user moves on")
    func permissionAnsweredInPlace() {
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .notifications), context: signedIn)
        var granted = signedIn
        granted.notifications = .granted
        let transition = flow.send(.contextChanged(granted))
        #expect(transition.direction == .none)
        #expect(flow.current == .notifications)
        #expect(flow.visibleSteps.contains(.notifications))
        #expect(flow.send(.advance).to == .installMac)
    }
}

struct OnboardingCloudStepTests {
    @Test func theCloudStepShowsOnlyWhenOfferedOnAFirstRun() {
        let offered = OnboardingContext(isSignedIn: true, notifications: .granted, localNetwork: .granted,
                                        hasTrustedMac: true, offersCloudMachine: true)
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .sshHost), context: offered)
        flow.send(.skipStep)
        #expect(flow.current == .cloudMachine)
        flow.send(.skipStep)
        #expect(flow.current == .celebrate)
        #expect(flow.progress.outcomes[.cloudMachine] == .skipped)

        var plain = offered
        plain.offersCloudMachine = false
        var without = OnboardingFlow(progress: OnboardingProgress(current: .sshHost), context: plain)
        without.send(.skipStep)
        #expect(without.current == .celebrate)

        var replay = offered
        replay.mode = .replay
        #expect(!OnboardingFlow(context: replay).applies(.cloudMachine))
    }
}
