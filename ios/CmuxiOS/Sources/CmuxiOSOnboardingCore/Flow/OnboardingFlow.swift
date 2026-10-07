import Foundation

/// The onboarding state machine. A value type: the UI model owns one, sends
/// events, persists `progress` after each transition and animates by the
/// returned direction. Applicability is evaluated against the live context,
/// so a step whose condition is already met is never shown or counted.
public struct OnboardingFlow: Hashable, Sendable {
    public private(set) var progress: OnboardingProgress
    public private(set) var context: OnboardingContext

    /// Resumes `progress` against today's context: a signed-out user in setup
    /// returns to sign-in, and a step that no longer applies is passed over.
    public init(progress: OnboardingProgress = .fresh, context: OnboardingContext) {
        self.progress = progress
        self.context = context
        normalize()
    }

    public var current: OnboardingStep { progress.current }
    public var isFinished: Bool { progress.finished }

    /// Whether `step` should show for this device and account right now.
    public func applies(_ step: OnboardingStep) -> Bool {
        Self.applies(step, progress: progress, context: context)
    }

    private static func applies(_ step: OnboardingStep, progress: OnboardingProgress, context: OnboardingContext) -> Bool {
        switch step {
        case .welcome, .approve, .reply:
            context.mode == .replay || progress.outcomes[step] != .skipped
        case .signIn:
            !context.isSignedIn
        case .notifications:
            context.isSignedIn && context.notifications == .notDetermined
        case .installMac, .pair:
            context.isSignedIn && !context.hasTrustedMac
        case .localNetwork:
            context.isSignedIn && !context.hasTrustedMac && context.localNetwork == .notDetermined
        case .sshHost:
            context.isSignedIn && context.mode == .firstRun
        case .celebrate:
            context.isSignedIn
        }
    }

    /// The steps the progress bar counts: the ones the user saw, the current
    /// one, and the ones still ahead that apply. Setup steps ahead of a
    /// signed-out user are counted as if signed in, so the bar does not grow
    /// after sign-in.
    public var visibleSteps: [OnboardingStep] {
        var projected = context
        projected.isSignedIn = true
        return OnboardingStep.allCases.filter { step in
            if step == current { return true }
            if step.order < current.order { return progress.outcomes[step] != nil && !isPassedTour(step) }
            if step.requiresSignIn { return Self.applies(step, progress: progress, context: projected) }
            return applies(step)
        }
    }

    /// The position of the current step in `visibleSteps`, from 0.
    public var position: (index: Int, total: Int) {
        let steps = visibleSteps
        return (steps.firstIndex(of: current) ?? 0, steps.count)
    }

    public var canGoBack: Bool { previousStep() != nil }
    public var canSkipIntro: Bool { !isFinished && current.isIntroPage }
    /// Optional steps; the tour pages use `skipIntro`, sign-in cannot be skipped.
    public var canSkipStep: Bool { !isFinished && current.phase == .setup && current != .celebrate }

    @discardableResult
    public mutating func send(_ event: OnboardingEvent) -> OnboardingTransition {
        let from = current
        guard !isFinished else { return OnboardingTransition(from: from, to: from, direction: .none) }
        switch event {
        case .advance:
            // Sign-in advances only when auth reports it (contextChanged).
            guard from != .signIn else { return OnboardingTransition(from: from, to: from, direction: .none) }
            return moveForward(ending: .completed)
        case .skipStep:
            guard canSkipStep else { return OnboardingTransition(from: from, to: from, direction: .none) }
            return moveForward(ending: .skipped)
        case .skipIntro:
            guard canSkipIntro else { return OnboardingTransition(from: from, to: from, direction: .none) }
            for step in OnboardingStep.allCases where step.isIntroPage && progress.outcomes[step] == nil {
                progress.outcomes[step] = .skipped
            }
            let target = applies(.signIn) ? .signIn : nextStep(after: .signIn)
            return land(on: target, from: from, direction: .forward, outcome: .skipped)
        case .back:
            guard let previous = previousStep() else { return OnboardingTransition(from: from, to: from, direction: .none) }
            progress.current = previous
            return OnboardingTransition(from: from, to: previous, direction: .backward)
        case .contextChanged(var next):
            next.mode = context.mode
            context = next
            if from == .signIn, next.isSignedIn {
                return moveForward(ending: .completed)
            }
            if from.requiresSignIn, !next.isSignedIn {
                progress.current = .signIn
                return OnboardingTransition(from: from, to: .signIn, direction: .backward)
            }
            return OnboardingTransition(from: from, to: from, direction: .none)
        }
    }

    // MARK: - Private

    private mutating func moveForward(ending outcome: StepOutcome) -> OnboardingTransition {
        let from = current
        progress.outcomes[from] = outcome
        return land(on: nextStep(after: from), from: from, direction: .forward, outcome: outcome)
    }

    private mutating func land(
        on target: OnboardingStep?, from: OnboardingStep, direction: OnboardingTransition.Direction,
        outcome: StepOutcome?
    ) -> OnboardingTransition {
        guard let target else {
            progress.finished = true
            return OnboardingTransition(from: from, to: from, direction: direction, finished: true, outcome: outcome)
        }
        progress.current = target
        return OnboardingTransition(from: from, to: target, direction: direction, outcome: outcome)
    }

    private func nextStep(after step: OnboardingStep) -> OnboardingStep? {
        OnboardingStep.allCases.first { $0.order > step.order && applies($0) }
    }

    private func previousStep() -> OnboardingStep? {
        guard !isFinished, current != .celebrate else { return nil }
        return OnboardingStep.allCases.last {
            $0.order < current.order && $0.phase == current.phase && applies($0)
        }
    }

    /// A tour page the user skipped is not counted once they are past it.
    private func isPassedTour(_ step: OnboardingStep) -> Bool {
        step.isIntroPage && progress.outcomes[step] == .skipped
    }

    private mutating func normalize() {
        guard !progress.finished else { return }
        if current.requiresSignIn, !context.isSignedIn {
            progress.current = .signIn
            return
        }
        guard !applies(current) else { return }
        if let next = nextStep(after: current) {
            progress.current = next
        } else {
            progress.finished = true
        }
    }
}
