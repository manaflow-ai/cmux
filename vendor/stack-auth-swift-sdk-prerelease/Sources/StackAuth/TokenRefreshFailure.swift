/// A refresh that could not produce credentials without changing session identity.
public enum TokenRefreshFailure: Error, Sendable {
    /// This caller cancelled its wait.
    case cancelled
    /// The shared exchange exceeded its total elapsed deadline.
    case timedOut
    /// The captured session was cleared or replaced while refreshing.
    case sessionChanged
}
