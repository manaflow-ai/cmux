public import Foundation
public import Observation

/// The app's one toast owner (c16-platform.md section 5). One toast shows at
/// a time; others queue in order. A toast whose key matches the visible or a
/// queued one refreshes it in place. The dwell runs in one cancellable task
/// through an injected sleep (no `asyncAfter`).
@MainActor
@Observable
public final class ToastCenter {
    public private(set) var current: Toast?
    public private(set) var queue: [Toast] = []
    @ObservationIgnored public let maxQueued: Int
    /// Scales every dwell; the overlay doubles it while VoiceOver runs.
    @ObservationIgnored public var dwellScale: @MainActor () -> Double = { 1 }
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private(set) var dwellTask: Task<Void, Never>?

    public init(maxQueued: Int = 4,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) }) {
        self.maxQueued = max(0, maxQueued)
        self.sleep = sleep
    }

    public func show(_ toast: Toast) {
        if let visible = current, visible.coalescingKey == toast.coalescingKey {
            current = toast.adopting(visible)
            startDwell()
            return
        }
        if let index = queue.firstIndex(where: { $0.coalescingKey == toast.coalescingKey }) {
            queue[index] = toast.adopting(queue[index])
            return
        }
        guard current != nil else {
            current = toast
            startDwell()
            return
        }
        queue.append(toast)
        while queue.count > maxQueued {
            // Failures are the last to go: drop the oldest other toast first.
            let victim = queue.firstIndex(where: { $0.style != .failure }) ?? 0
            queue.remove(at: victim)
        }
    }

    public func dismissCurrent() {
        guard current != nil else { return }
        advance()
    }

    /// Dismisses the toast with `id`, visible or queued.
    public func dismiss(_ id: Toast.ID) {
        if current?.id == id {
            advance()
        } else {
            queue.removeAll { $0.id == id }
        }
    }

    /// Runs the visible toast's action, then dismisses it.
    public func performAction() {
        guard let action = current?.action else { return }
        advance()
        action.handler()
    }

    private func advance() {
        dwellTask?.cancel()
        dwellTask = nil
        current = queue.isEmpty ? nil : queue.removeFirst()
        startDwell()
    }

    private func startDwell() {
        dwellTask?.cancel()
        dwellTask = nil
        guard let toast = current, case .after(let duration) = toast.dwell else { return }
        let scaled = duration * max(1, dwellScale())
        let sleep = self.sleep
        let id = toast.id
        dwellTask = Task { [weak self] in
            do { try await sleep(scaled) } catch { return }
            guard !Task.isCancelled else { return }
            self?.dwellElapsed(id)
        }
    }

    private func dwellElapsed(_ id: Toast.ID) {
        guard current?.id == id else { return }
        advance()
    }
}
