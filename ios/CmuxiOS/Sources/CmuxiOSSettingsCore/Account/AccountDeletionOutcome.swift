/// The backend accepted account deletion.
public enum AccountDeletionOutcome: Hashable, Sendable {
    case completed
    /// Stack deleted the account, but some cmux cleanup needs support.
    case completedWithIncompleteServerCleanup
}
