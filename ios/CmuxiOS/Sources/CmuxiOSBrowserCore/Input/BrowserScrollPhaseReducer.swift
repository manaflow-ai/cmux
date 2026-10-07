public import CmuxiOSFeatureKit

/// Turns pan tracking and deceleration callbacks into wheel phases: the
/// finger drives `phase`, the fling after it drives `momentumPhase`.
public struct BrowserScrollPhaseReducer: Hashable, Sendable {
    public enum Event: Hashable, Sendable {
        case trackingBegan, trackingChanged
        case trackingEnded(willDecelerate: Bool)
        case momentumChanged, momentumEnded
        case cancelled
    }

    private enum State: Hashable, Sendable { case idle, tracking, momentum }
    private var state: State = .idle

    public init() {}

    /// The (phase, momentumPhase) pair to send for `event`.
    public mutating func consume(_ event: Event) -> (BrowserGesturePhase, BrowserGesturePhase) {
        switch event {
        case .trackingBegan:
            state = .tracking
            return (.began, .none)
        case .trackingChanged:
            if state != .tracking {
                state = .tracking
                return (.began, .none)
            }
            return (.changed, .none)
        case .trackingEnded(let decelerates):
            state = decelerates ? .momentum : .idle
            return (.ended, decelerates ? .began : .none)
        case .momentumChanged:
            if state != .momentum {
                state = .momentum
                return (.none, .began)
            }
            return (.none, .changed)
        case .momentumEnded:
            state = .idle
            return (.none, .ended)
        case .cancelled:
            state = .idle
            return (.cancelled, .none)
        }
    }
}
