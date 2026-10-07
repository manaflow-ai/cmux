/// Seam over the kept auth runtime for the Account section. The owner of the
/// account and team selection is Stack Auth; the app target adapts
/// `AuthCoordinator` (`StackAccountController`).
@MainActor
public protocol AccountControlling: AnyObject {
    var snapshot: AccountSnapshot { get }
    /// Every change, starting with the current snapshot.
    func updates() -> AsyncStream<AccountSnapshot>
    /// Persists the selection at the owner before the local projection changes.
    func selectTeam(_ id: AccountTeam.ID) async throws
    /// Permanently deletes the account through cmux's backend. Does not sign out.
    func deleteAccount() async -> Result<AccountDeletionOutcome, AccountDeletionFailure>
    /// Signs out through the normal owner (install revocation runs first).
    func signOut() async
}
