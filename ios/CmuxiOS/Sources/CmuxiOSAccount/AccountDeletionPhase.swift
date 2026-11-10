/// Where Settings > Delete Account is. The model moves through these in
/// order; a failure can retry straight into `deleting` (the person already
/// confirmed) or go back to `idle`.
public enum AccountDeletionPhase: Equatable, Sendable {
    /// The Delete Account row, ready.
    case idle
    /// The destructive confirmation is up.
    case confirming
    /// The request is out; the row shows progress and nothing else can start.
    case deleting
    /// The request did not delete the account; the row offers Try Again.
    case failed(AccountDeletionFailure)
    /// The account is gone; sign-out follows.
    case deleted
}
