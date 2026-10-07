/// An account for previews, demo mode and tests: two teams, an instant
/// team switch, and a configurable deletion result.
@MainActor
public final class MockAccountController: AccountControlling {
    public private(set) var snapshot: AccountSnapshot {
        didSet { for continuation in subscribers { continuation.yield(snapshot) } }
    }
    public var deletionResult: Result<AccountDeletionOutcome, AccountDeletionFailure>
    /// Team ids the mock owner refuses to select.
    public var refusedTeams: Set<AccountTeam.ID> = []
    public private(set) var signOutCount = 0
    private var subscribers: [AsyncStream<AccountSnapshot>.Continuation] = []

    public init(snapshot: AccountSnapshot = MockAccountController.sample,
                deletionResult: Result<AccountDeletionOutcome, AccountDeletionFailure> = .success(.completed)) {
        self.snapshot = snapshot
        self.deletionResult = deletionResult
    }

    public static let sample = AccountSnapshot(
        displayName: "Ada Lovelace", email: "ada@example.com",
        teams: [AccountTeam(id: "team-personal", name: "Personal"), AccountTeam(id: "team-manaflow", name: "Manaflow")],
        selectedTeamID: "team-personal"
    )

    public func updates() -> AsyncStream<AccountSnapshot> {
        let (stream, continuation) = AsyncStream<AccountSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(snapshot)
        subscribers.append(continuation)
        return stream
    }

    public func selectTeam(_ id: AccountTeam.ID) async throws {
        guard snapshot.teams.contains(where: { $0.id == id }), !refusedTeams.contains(id) else {
            throw MockAccountRefusal()
        }
        snapshot.selectedTeamID = id
    }

    public func deleteAccount() async -> Result<AccountDeletionOutcome, AccountDeletionFailure> {
        deletionResult
    }

    public func signOut() async {
        signOutCount += 1
    }
}
