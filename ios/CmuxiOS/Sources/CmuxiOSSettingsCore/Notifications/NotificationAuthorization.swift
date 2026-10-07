/// The system's notification permission for the app, as Settings shows it.
public enum NotificationAuthorization: Hashable, Sendable {
    case notDetermined
    case denied
    case authorized
}
