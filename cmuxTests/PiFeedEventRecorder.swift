import CMUXAgentLaunch
import Foundation

/// Safety: every access to `recordedEvents` is serialized by `lock`.
final class PiFeedEventRecorder: @unchecked Sendable {
    /// Narrow synchronous test-recorder carve-out: critical sections only copy or append a value.
    private let lock = NSLock()
    private var recordedEvents: [WorkstreamEvent] = []

    var events: [WorkstreamEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func record(_ event: WorkstreamEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}
