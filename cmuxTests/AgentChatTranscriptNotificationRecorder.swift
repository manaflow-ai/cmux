import Foundation

// NotificationCenter is thread-safe; the only added storage is an immutable,
// Sendable AsyncStream continuation, so recording adds no mutable shared state.
final class AgentChatTranscriptNotificationRecorder: NotificationCenter, @unchecked Sendable {
    enum Event: Sendable {
        case added(name: Notification.Name?, observerID: ObjectIdentifier)
        case removed(observerID: ObjectIdentifier, onMainThread: Bool)
    }

    private let events: AsyncStream<Event>.Continuation

    init(events: AsyncStream<Event>.Continuation) {
        self.events = events
        super.init()
    }

    override func addObserver(
        forName name: Notification.Name?,
        object obj: Any?,
        queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> any NSObjectProtocol {
        let observer = super.addObserver(forName: name, object: obj, queue: queue, using: block)
        events.yield(.added(name: name, observerID: ObjectIdentifier(observer as AnyObject)))
        return observer
    }

    override func removeObserver(_ observer: Any) {
        super.removeObserver(observer)
        events.yield(.removed(
            observerID: ObjectIdentifier(observer as AnyObject),
            onMainThread: Thread.isMainThread
        ))
    }
}
