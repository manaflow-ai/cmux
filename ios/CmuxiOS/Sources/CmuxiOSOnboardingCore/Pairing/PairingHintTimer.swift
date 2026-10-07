import Foundation

/// Raises the pair step's help line after a quiet search. An intentional,
/// cancellable delay on an injected clock (no `asyncAfter`); restarting
/// cancels the previous wait.
@MainActor
public final class PairingHintTimer {
    public static let defaultDelay: Duration = .seconds(8)

    private let clock: any Clock<Duration>
    private let delay: Duration
    private var task: Task<Void, Never>?

    public init(clock: any Clock<Duration>, delay: Duration = PairingHintTimer.defaultDelay) {
        self.clock = clock
        self.delay = delay
    }

    /// Calls `fire` once after the delay unless cancelled or restarted first.
    public func start(_ fire: @escaping @MainActor () -> Void) {
        task?.cancel()
        let clock = clock
        let delay = delay
        task = Task { @MainActor in
            do { try await clock.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            fire()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    /// The pending wait, for tests that await the fire.
    public var pending: Task<Void, Never>? { task }
}
