import CmuxHomeRender
import Foundation

/// The render core's one-shot cleanup deadline on the main run loop. One
/// `Timer` that does not repeat, scheduled in the common modes so it also
/// fires while the user drags the transcript. Nothing polls: the timer
/// exists only between `schedule` and its single fire; after the owner
/// goes away a pending fire finds `self` nil and does nothing.
@MainActor
final class HomeRunLoopDeadline: HomeDeadline {
    private var timer: Timer?

    func schedule(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void) {
        timer?.invalidate()
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        let timer = Timer(timeInterval: max(0, seconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                action()
            }
        }
        // Cleanup runs after animations end; a few ms late is invisible.
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
