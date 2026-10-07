/// The system's notification permission for the app, as Settings shows it.
public enum NotificationAuthorization: Hashable, Sendable {
    case notDetermined
    case denied
    case authorized
    /// Delivered quietly to Notification Center (provisional or ephemeral).
    case quiet
}
