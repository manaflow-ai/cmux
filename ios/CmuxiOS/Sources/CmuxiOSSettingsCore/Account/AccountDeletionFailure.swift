/// What the user is told after Delete Account did not simply complete. Same
/// kinds and copy as the shipping app (`DeleteAccountFailureKind`).
public enum AccountDeletionFailure: Error, Hashable, Sendable {
    case generic
    /// The request failed before it could reach the server.
    case connection
    /// The session is no longer valid.
    case unauthorized
    /// cmux data was deleted but Stack account deletion did not finish.
    case stackDeleteIncomplete
    /// The account is gone but some cmux cleanup did not finish.
    case serverCleanupIncomplete
    case timedOut
    /// No definitive answer came back.
    case unknown

    /// The account no longer exists (or the session is dead), so the device
    /// signs out once the user dismisses the alert.
    public var signsOutAfterAcknowledgement: Bool {
        self == .serverCleanupIncomplete || self == .unauthorized
    }
}
