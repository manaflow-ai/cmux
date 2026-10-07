import Foundation

/// What one event did. `direction` drives the slide; `.none` means the
/// step did not change.
public struct OnboardingTransition: Hashable, Sendable {
    public enum Direction: Hashable, Sendable {
        case forward
        case backward
        case none
    }

    public var from: OnboardingStep
    public var to: OnboardingStep
    public var direction: Direction
    /// The flow just finished with this event.
    public var finished: Bool
    /// The outcome recorded for `from`, when the event ended it.
    public var outcome: StepOutcome?

    public init(
        from: OnboardingStep, to: OnboardingStep, direction: Direction, finished: Bool = false,
        outcome: StepOutcome? = nil
    ) {
        self.from = from
        self.to = to
        self.direction = direction
        self.finished = finished
        self.outcome = outcome
    }

    public var changedStep: Bool { from != to || finished }
}
