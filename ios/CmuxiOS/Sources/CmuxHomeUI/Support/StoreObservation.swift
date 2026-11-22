import Foundation
import Observation

/// Runs `render` inside `withObservationTracking`, and runs it again after
/// any observed property changes. The tracking fires once per arm (on the
/// first `willSet`), and the re-render runs in a later main-actor job, so a
/// burst of store mutations in one turn produces one render.
///
/// `render` must read every store property the screen depends on; whatever
/// it reads is what is tracked for the next change.
@MainActor
final class StoreObservation {
    private let render: @MainActor () -> Void
    private var isActive = false
    /// Bumps on every `start` so a callback from an older arm does nothing.
    private var generation = 0

    init(render: @escaping @MainActor () -> Void) {
        self.render = render
    }

    /// Renders now and starts tracking. Calling it again re-renders.
    func start() {
        isActive = true
        generation += 1
        arm()
    }

    func stop() {
        isActive = false
        generation += 1
    }

    /// Renders now (for changes that are not store properties, such as options).
    func renderNow() {
        guard isActive else { return }
        generation += 1
        arm()
    }

    private func arm() {
        let armed = generation
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.changed(armed)
            }
        }
    }

    private func changed(_ armed: Int) {
        // The tracking fired on the first mutation; this job runs after the
        // mutating job finished, so every mutation of that turn is included.
        guard isActive, armed == generation else { return }
        generation += 1
        arm()
    }
}
