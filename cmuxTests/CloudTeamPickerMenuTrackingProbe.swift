import AppKit

/// Runs a nested loop, like `NSMenu.popUp`, and records whether main-queue
/// work can run before tracking returns.
@MainActor
final class CloudTeamPickerMenuTrackingProbe {
    private var queueDrained = false
    private(set) var drainedWhileTracking: Bool?

    func track() {
        queueDrained = false
        // Deliberately queue work: this regression detects starvation when
        // the anchor enters the nested run loop from a main-queue callout.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.queueDrained = true }
        }
        let deadline = Date().addingTimeInterval(1)
        while !queueDrained, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: deadline)
        }
        drainedWhileTracking = queueDrained
    }
}
