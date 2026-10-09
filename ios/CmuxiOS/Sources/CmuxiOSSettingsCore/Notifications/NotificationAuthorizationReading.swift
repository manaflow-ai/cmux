/// Reads and requests the system notification permission. The app adapts
/// its permission center (which also tells push registration to continue).
@MainActor
public protocol NotificationAuthorizationReading: AnyObject {
    func status() async -> NotificationAuthorization
    /// Shows the system prompt when it can still show; returns the answer.
    func request() async -> NotificationAuthorization
}
